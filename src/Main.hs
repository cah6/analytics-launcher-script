#!/usr/bin/env stack
-- stack --install-ghc runghc --package turtle
{-# LANGUAGE LambdaCase, DeriveGeneric, OverloadedStrings #-}

import Prelude hiding (mapM_)
import Data.Aeson
import Data.Aeson.Types()
import qualified Data.ByteString.Lazy as B
import Data.Maybe()
import Data.Text (unpack, unwords, isPrefixOf, stripPrefix, replace)
import Filesystem.Path.CurrentOS (encodeString)

import Debug.Trace ()
import Turtle as T
import Turtle.Format()

import Data.List
import Data.ConfigFile()

import Network.Wreq as N
import Control.Retry as R

import Control.Concurrent
import Control.Concurrent.MVar (MVar, newEmptyMVar)
import Control.Monad (void)
import Control.Monad.Managed()
import Control.Monad.Parallel (mapM_)

import Control.Exception

import System.Process as P
import System.Process.Internals
import System.Posix.Signals as Signals

import GHC.Generics
import Debug.Trace (trace)

-- TODO / ideas list
-- use reader to pass around config I get from the start

-- type Application m = ReaderT ProgramArgs m ()

main :: IO ()
main = do
  args <- T.options "Script to start up SaaS-like analytics cluster." optionsParser
  currDir <- pwd
  config <- makeNodeConfig currDir (planPath args)
  print config
  homeDir <- getPropOrDie "ANALYTICS_HOME" "Set it to be something like /Users/firstname.lastname/appdynamics/analytics-codebase/analytics"
  cd homeDir
  shellsNoArgs "./gradlew --build-cache -p analytics-processor clean distZip"
  cd "analytics-processor/build/distributions"
  baseDir <- pwd
  -- unzip all nodes and join
  sh $ parallel $ unzipCmds (map nodeName config)
  -- run all the nodes
  _ <- startAllNodes (not (doNotKillAll args)) baseDir config
  -- should not hit this until you ctrl+c and all nodes stop
  putStrLn "End of the script!"

makeNodeConfig :: T.FilePath -> T.FilePath -> IO NodeConfigs
makeNodeConfig basePath relativePath = do
  planInBytes <- B.readFile (encodeString $ basePath <> relativePath)
  case eitherDecode planInBytes of
    Left readErr  -> die $ fromString $ "Could not read input file into plan object: " <> readErr
    Right val     -> return val

optionsParser :: T.Parser ProgramArgs
optionsParser = ProgramArgs
  <$> optPath "plan" 'p' "Location of json file that defines which nodes are started."
  <*> switch "no-kill-all" 'n' "Set to turn off default behavior of killing all nodes if one dies."

data ProgramArgs = ProgramArgs {
    planPath      :: T.FilePath
  , doNotKillAll  :: Bool
  }


unzipCmds :: [Text] -> [IO ()]
unzipCmds = map (shellsNoArgs . (<>) "unzip analytics-processor.zip -d ")

startAllNodes :: Bool -> T.FilePath -> NodeConfigs -> IO ()
startAllNodes shouldKillAll baseDir config = do
  hasCleanupStarted <- newEmptyMVar
  let (esNodes, otherNodes) = partition isStoreConfig config
  esNodeHandles <- startNodes baseDir esNodes
  -- wait for ES
  esPort <- getElasticsearchPort config
  tryWaitForElasticsearch esNodeHandles esPort
  putStrLn "Elasticsearch is up now!"
  -- bring up others
  nonEsNodeHandles <- startNodes baseDir otherNodes
  -- install handlers and wait for all
  let allHandles = esNodeHandles ++ nonEsNodeHandles
  _ <- installHandler sigINT (killHandles hasCleanupStarted allHandles) Nothing
  _ <- installHandler sigTERM (killHandles hasCleanupStarted allHandles) Nothing
  mapM_ (waitOrCleanupAll shouldKillAll hasCleanupStarted allHandles) allHandles
  return ()

waitOrCleanupAll :: Bool -> MVar () -> [ProcessHandle] -> ProcessHandle -> IO ()
waitOrCleanupAll shouldKillAll cleanupMVar allHandles thisHandle = getPid thisHandle >>= \case
  Nothing   -> when shouldKillAll $ tryKillAll cleanupMVar allHandles
  Just pid  -> do
    exitCode <- waitForProcess thisHandle
    firstTimeCleanup <- isEmptyMVar cleanupMVar
    case exitCode of
      ExitSuccess -> return ()
      ExitFailure code ->
        when (firstTimeCleanup && shouldKillAll) $ trace
          ("Killing all handles since " <> show pid <> " stopped with " <> show code)
          (tryKillAll cleanupMVar allHandles)

isStoreConfig :: NodeConfig -> Bool
isStoreConfig config = "store" `Data.Text.isPrefixOf` name || "api-store" `Data.Text.isPrefixOf` name where
  name = nodeName config

getVmOptionsFile :: T.FilePath -> NodeConfig -> T.FilePath
getVmOptionsFile baseDir nodeConfig =
  if isStoreConfig nodeConfig
    then fromText $ vmOptionsFileFormat "analytics-sidecar"
    else fromText $ vmOptionsFileFormat "analytics-processor"
  where
    vmOptionsFileFormat = format (fp % "/" %s % "/analytics-processor/conf/" %s % ".vmoptions") baseDir (nodeName nodeConfig)

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
tryWaitForElasticsearch handles esPort = catch (waitForElasticsearch esPort) (handleError handles)

handleError :: [ProcessHandle] -> SomeException -> IO ()
handleError handles someE = kill9All handles >>= throw someE

waitForElasticsearch :: Text -> IO ()
waitForElasticsearch esPort = recoverAll (R.constantDelay 1000000 <> R.limitRetries 60) go where
  go _ = trace "Waiting for Elasticsearch to start up..." $
          void $ N.get ("http://localhost:" <> unpack esPort)

startNodes :: T.FilePath -> NodeConfigs -> IO [ProcessHandle]
startNodes baseDir configs = do
  _ <- traverse (editVmOptionsFile baseDir) configs
  _ <- traverse (editVersionFile baseDir) configs
  traverse (shellReturnHandle . configToStartCmd baseDir) configs

editVmOptionsFile :: T.FilePath -> NodeConfig -> IO ()
editVmOptionsFile baseDir nodeConfig = go (getVmOptionsFile baseDir nodeConfig) (debugOption nodeConfig) where
  go :: T.FilePath -> Maybe DebugOption -> IO ()
  go _ Nothing = return ()
  go vmOptionsFile (Just vmoption) = append vmOptionsFile (fromString $ unpack vmoption)

editVersionFile :: T.FilePath -> NodeConfig -> IO ()
editVersionFile baseDir config = editVersion versionFp (version config) where
  versionFp = fromText $ format (fp%"/"%s%"/analytics-processor/version.txt") baseDir (nodeName config)

editVersion :: T.FilePath -> Maybe Version -> IO ()
editVersion _ Nothing = return ()
editVersion versionFp (Just versionOverride) = do
  versionFile <- readTextFile versionFp
  let newVersionFile = replace "0.0.0.0" versionOverride versionFile
  writeTextFile versionFp newVersionFile

killHandles :: MVar () -> [ProcessHandle] -> Signals.Handler
killHandles hasCleanupStarted handles = Catch $ tryKillAll hasCleanupStarted handles

tryKillAll :: MVar () -> [ProcessHandle] -> IO ()
tryKillAll cleanupMvar handles = do
  cleanupHadNotStarted <- tryPutMVar cleanupMvar ()
  when cleanupHadNotStarted (kill9All handles)

kill9All :: [ProcessHandle] -> IO ()
kill9All phs = void $ traverse kill9 phs

kill9 :: ProcessHandle -> IO ()
kill9 ph = void $ forkIO $ do
  _ <- getPid ph >>= \case
    Nothing -> return ()
    Just a  -> void $ trace ("Soft killing process with id: [" ++ show a ++ "], will hard kill in 5 seconds if it's still alive") $
      shellNoArgs (fromString ("kill " ++ show a))
  sleep 5.0
  _ <- getPid ph >>= \case
    Nothing -> return ()
    Just a  -> void $ trace ("Hard killing process with id: " ++ show a) $ shellNoArgs (fromString ("kill -9 " ++ show a))
  return ()

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
getPropertyOverrideString nodeConfig = Data.Text.unwords $ map (\prop -> "-D " <> prop) (propertyOverrides nodeConfig)

shellReturnHandle :: Text -> IO ProcessHandle
shellReturnHandle cmd = do
  (_, _, _, ph) <- createProcess (P.shell (unpack cmd))
  return ph

getPid :: ProcessHandle -> IO (Maybe PHANDLE)
getPid ph = withProcessHandle ph $ \case
  OpenHandle pid  -> return $ Just pid
  _               -> return Nothing

-- a few basic util methods that helped me

shellNoArgs :: Text -> IO ExitCode
shellNoArgs cmd = T.shell cmd empty

shellsNoArgs :: Text -> IO ()
shellsNoArgs cmd = shells cmd empty

getPropOrDie :: Text -> Text -> IO T.FilePath
getPropOrDie prop message = need prop >>= \case
  Nothing -> die (prop <> " was not set. " <> message)
  Just a  -> return $ fromText a

type NodeConfigs = [NodeConfig]
data NodeConfig = NodeConfig {
    nodeName :: NodeName
  , propertyOverrides :: [PropertyOverride]
  , debugOption :: Maybe DebugOption
  , version :: Maybe Version
  } deriving (Generic, Show)

instance ToJSON NodeConfig
instance FromJSON NodeConfig

type NodeName = Text
type PropertyOverride = Text
type DebugOption = Text
type Version = Text
