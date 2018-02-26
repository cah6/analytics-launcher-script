#!/usr/bin/env stack
-- stack --install-ghc runghc --package turtle
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveGeneric #-}

import Data.Aeson
import Data.Aeson.Types
import qualified Data.ByteString.Lazy as B
import Data.Maybe
import Data.Text (unpack, unwords, isPrefixOf, stripPrefix)
import Filesystem.Path.CurrentOS (encodeString, decodeString)

import Debug.Trace
import Turtle as T
import Turtle.Format

import Data.List
import Data.ConfigFile

import Network.Wreq as N
import Control.Retry as R

import Control.Concurrent
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, tryTakeMVar)
import Control.Monad (void)
import Control.Monad.Managed

import Control.Exception

import System.Process as P
import System.Process.Internals
import System.Posix.Signals as Signals

import GHC.Generics

-- todo / ideas list
-- use reader to pass around config I get from the start
-- partition by nodes in tier store-* instead of getting list head and tail
-- call sigterm, wait for a bit, then kill 9
-- edit version file to user input version
-- look for "Stopping " in logs, stop startup if it happens

main = do
  planPath <- T.options "Script to start up SaaS-like analytics cluster." optionsParser
  currDir <- pwd
  config <- makeNodeConfig currDir planPath
  print config
  home <- getPropOrDie "ANALYTICS_HOME" "Set it to be something like /Users/firstname.lastname/appdynamics/analytics-codebase/analytics"
  cd home
  shellsNoArgs "./gradlew --build-cache -p analytics-processor clean distZip"
  cd "analytics-processor/build/distributions"
  baseDir <- pwd
  -- unzip all nodes and join
  sh $ parallel $ unzipCmds (map nodeName config)
  -- run all the nodes
  _ <- startAllNodes baseDir config
  -- should not hit this until you ctrl+c
  putStrLn "End of the script!"

makeNodeConfig :: T.FilePath -> T.FilePath -> IO NodeConfigs
makeNodeConfig basePath relativePath = do
  planInBytes <- B.readFile (encodeString $ basePath <> relativePath)
  case eitherDecode planInBytes of
    Left err  -> die $ fromString $ "Could not read input file into plan object: " <> err
    Right val -> return val

optionsParser :: T.Parser T.FilePath
optionsParser = optPath "plan" 'p' "The cluster json plan to use."

unzipCmds :: [Text] -> [IO ()]
unzipCmds = map (shellsNoArgs . (<>) "unzip analytics-processor.zip -d ")

startAllNodes :: T.FilePath -> NodeConfigs -> IO ()
startAllNodes baseDir config = do
  let (esNodes, otherNodes) = partition isStoreConfig config
  esNodeHandles <- startNodes baseDir [head config]
  -- wait for ES
  esPort <- getElasticsearchPort config
  tryWaitForElasticsearch esNodeHandles esPort
  putStrLn "Elasticsearch is up now!"
  -- bring up others
  nonEsNodeHandles <- startNodes baseDir (tail config)
  -- install handlers and wait for all
  let allHandles = esNodeHandles ++ nonEsNodeHandles
  mpids <- traverse getPid allHandles
  let pids = catMaybes mpids
  _ <- installHandler sigINT (killHandles pids) Nothing
  _ <- installHandler sigTERM (killHandles pids) Nothing
  void $ traverse waitForProcess allHandles
  return ()

isStoreConfig :: NodeConfig -> Bool
isStoreConfig config = "store" `Data.Text.isPrefixOf` name || "api-store" `Data.Text.isPrefixOf` name where
  name = nodeName config

getElasticsearchPort :: NodeConfigs -> IO Text
getElasticsearchPort configs = case getOptElasticsearchPort configs of
    Nothing -> die "ad.es.node.http.port wasn't set in elasticsearch property overrides"
    Just a  -> return a

getOptElasticsearchPort :: NodeConfigs -> Maybe Text
getOptElasticsearchPort configs = do
  let portPrefix = "ad.es.node.http.port=" :: Text
  let isPortProp p = portPrefix `Data.Text.isPrefixOf` p
  let esProps = propertyOverrides (head configs)
  portProp <- Data.List.find isPortProp esProps
  Data.Text.stripPrefix portPrefix portProp

tryWaitForElasticsearch :: [ProcessHandle] -> Text -> IO ()
tryWaitForElasticsearch handles esPort = catch (waitForElasticsearch esPort) (\e -> do
  let err = show (e :: SomeException)
  mpids <- traverse getPid handles
  let pids = catMaybes mpids
  traverse (kill9 . show) pids
  throw e
  )

waitForElasticsearch :: Text -> IO ()
waitForElasticsearch esPort = recoverAll (R.constantDelay 1000000 <> R.limitRetries 30) go where
  go _ = trace "Waiting for Elasticsearch to start up..." $
          void $ N.get ("http://localhost:" <> unpack esPort)

startNodes :: T.FilePath -> NodeConfigs -> IO [ProcessHandle]
startNodes baseDir configs = do
  _ <- traverse (editVmOptionsFile baseDir) configs
  traverse (shellReturnHandle . configToStartCmd baseDir) configs

editVmOptionsFile :: T.FilePath -> NodeConfig -> IO ()
editVmOptionsFile baseDir nodeConfig = go fileLocation (debugOption nodeConfig) where
  go :: T.FilePath -> Maybe DebugOption -> IO ()
  go _ Nothing = return ()
  go vmOptionsFile (Just vmoption) = append vmOptionsFile (fromString $ unpack vmoption)

  fileLocation :: T.FilePath
  fileLocation = fromText $ format (fp%"/"%s%"/analytics-processor/conf/analytics-processor.vmoptions") baseDir (nodeName nodeConfig)

--editVersionFile :: T.FilePath -> IO Text
--editVersionFile baseDir nodeConfig =

killHandles :: [PHANDLE] -> Signals.Handler
killHandles = Catch . void . traverse (kill9 . show)

kill9 :: String -> IO ()
kill9 pid = void $ trace ("Killing process with id: " ++ pid) $ shellNoArgs (fromString ("kill -9 " ++ pid))

configToStartCmd :: T.FilePath -> NodeConfig -> Text
configToStartCmd baseDir nodeConfig = finalCmd where
  confDir = format (s%"/conf") apDir
  apDir = format (fp%"/"%s%"/analytics-processor") baseDir (nodeName nodeConfig)
  shFile = format (s%"/bin/analytics-processor.sh") apDir
  propFile = format (s%"/analytics-"%s%".properties") confDir (nodeName nodeConfig)
  logPathProp = format ("-D ad.dw.log.path="%s%"/logs") apDir
  extraProps = format (s%" "%s) logPathProp $ getPropertyOverrideString nodeConfig
  finalCmd = format ("sh "%s%" start -p "%s%" "%s) shFile propFile extraProps

getPropertyOverrideString :: NodeConfig -> Text
getPropertyOverrideString nodeConfig = Data.Text.unwords $ map (\s -> "-D " <> s) (propertyOverrides nodeConfig)

shellReturnHandle :: Text -> IO ProcessHandle
shellReturnHandle cmd = do
  (_, _, _, phandle) <- createProcess (P.shell (unpack cmd))
  return phandle

getPid :: ProcessHandle -> IO (Maybe PHANDLE)
getPid ph = withProcessHandle ph go where
  go ph_ = case ph_ of
              OpenHandle x   -> return $ Just x
              ClosedHandle _ -> return Nothing

-- a few basic util methods that helped me

shellNoArgs :: Text -> IO ExitCode
shellNoArgs cmd = T.shell cmd empty

shellsNoArgs :: Text -> IO ()
shellsNoArgs cmd = shells cmd empty

getPropOrDie :: Text -> Text -> IO T.FilePath
getPropOrDie prop message = do
  homeDir <- need prop
  case homeDir of
    Nothing -> die (prop <> " was not set. " <> message)
    Just a  -> return $ fromText a

type NodeConfigs = [NodeConfig]
data NodeConfig = NodeConfig {
    nodeName :: NodeName
  , propertyOverrides :: [PropertyOverride]
  , debugOption :: Maybe DebugOption
  } deriving (Generic, Show)

instance ToJSON NodeConfig
instance FromJSON NodeConfig

type NodeName = Text
type PropertyOverride = Text
type DebugOption = Text
