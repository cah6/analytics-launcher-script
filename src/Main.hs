#!/usr/bin/env stack
-- stack --install-ghc runghc --package turtle                          
{-# LANGUAGE OverloadedStrings #-} 

import Data.Maybe
import Data.Text (unpack) 

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

main = do
  home <- getPropOrDie "ANALYTICS_HOME" "Set it to be something like /Users/firstname.lastname/appdynamics/analytics-codebase/analytics"
  cd home
  shellsNoArgs "./gradlew --build-cache -p analytics-processor clean distZip"
  cd "analytics-processor/build/distributions"
  baseDir <- pwd
  -- unzip all nodes and join 
  sh $ parallel $ unzipCmds (map nodeName config)
  -- run all the nodes
  runManaged (startAllNodes baseDir)
  -- should not hit this until you ctrl+c
  putStrLn "End of the script!"
  where 
    getFst (a, b, c) = a 

unzipCmds :: [String] -> [IO ()]
unzipCmds = map (shellsNoArgs . fromString . (++) "unzip analytics-processor.zip -d ") 

-- this is "managed" because we want ES to start async but be brought down when we quit the program
startAllNodes :: T.FilePath -> Managed ()
startAllNodes baseDir = do 
  ref <- fork (startEs baseDir)
  liftIO waitForElasticsearch
  using $ sh $ liftIO $ startNonEsNodes baseDir
  return ()

startEs :: T.FilePath -> IO ()
startEs baseDir = shellsNoArgs $ configToStartCmd baseDir (head config)

waitForElasticsearch :: IO ()
waitForElasticsearch = recoverAll (R.constantDelay 1000000 <> R.limitRetries 30) go where 
  go _ = trace "Waiting for Elasticsearch to start up..." $
          void $ N.get "http://localhost:9400"

startNonEsNodes :: T.FilePath -> IO ()
startNonEsNodes baseDir = do 
  mhandles <- traverse (shellReturnHandle . configToStartCmd baseDir) (tail config)
  mpids <- traverse getPid mhandles
  let pids = map fromJust $ filter isJust mpids
  _ <- installHandler sigINT (killHandles pids) Nothing
  _ <- installHandler sigTERM (killHandles pids) Nothing
  void $ traverse waitAndPrintWhenFinished (zip mhandles mpids)

-- todo: can probably just remove this
waitAndPrintWhenFinished :: (ProcessHandle, Maybe PHANDLE) -> IO ()
waitAndPrintWhenFinished (_, Nothing) = putStrLn "One of the processes ended before we could get to it."
waitAndPrintWhenFinished (ph, Just pid) = do 
  exitCode <- waitForProcess ph 
  print ("Process with id " <> show pid <> " exited with code " <> show exitCode)

killHandles :: [PHANDLE] -> Signals.Handler
killHandles = Catch . void . traverse (kill9 . show)

kill9 :: String -> IO () 
kill9 pid = void $ trace ("Killing process with id: " ++ pid) $ shellNoArgs (fromString ("kill -9 " ++ pid))

configToStartCmd :: T.FilePath -> NodeConfig -> Text
configToStartCmd baseDir nodeConfig = finalCmd where 
  confDir = format (s%"/conf") apDir 
  apDir = format (fp%"/"%s%"/analytics-processor") baseDir (fromString $ nodeName nodeConfig)
  shFile = format (s%"/bin/analytics-processor.sh") apDir
  propFile = format (s%"/analytics-"%s%".properties") confDir (fromString $ nodeName nodeConfig) 
  logPathProp = format ("-D ad.dw.log.path="%s%"/logs") apDir
  extraProps = format (s%" "%s) logPathProp $ (fromString . unwords) (propertyOverrides nodeConfig)
  finalCmd = format ("sh "%s%" start -p "%s%" "%s) shFile propFile extraProps

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

-- apiStoreConfig = [
--     ("api-store", [
--         "-D ad.dw.log.path=logs"
--       , "-D ad.admin.cluster.name=appdynamics-analytics-cluster"
--     ])
--   ]

-- hack_config = [
--     ("hackathon", [
--         "-D ad.dw.log.path=logs"
--     ])
--   ]

type NodeConfigs = [NodeConfig]
data NodeConfig = NodeConfig {
    nodeName :: NodeName
  , propertyOverrides :: [PropertyOverride]
  , extraVmOption :: Maybe ExtraVmOption
  }
type NodeName = String
type PropertyOverride = String
type ExtraVmOption = String

javaDebugString = "-agentlib:jdwp=transport=dt_socket,server=y,suspend=n,address=5005"

config :: NodeConfigs
config = [
    NodeConfig {
      nodeName = "store-master"
    , propertyOverrides = [
          "-D ad.es.node.minimum_master_nodes=1"
        , "-D ad.dw.http.port=9050"
        , "-D ad.dw.http.adminPort=9051"
        ]
    , extraVmOption = Nothing
    }
  , NodeConfig {
      nodeName = "api"
    , propertyOverrides = [
          "-D ad.admin.cluster.name=appdynamics-analytics-cluster"
        , "-D ad.admin.cluster.unicast.hosts.fallback=localhost:9300"
        , "-D ad.es.event.index.replicas=0"
        , "-D ad.es.metadata.replicas=0"
        , "-D ad.es.metadata.entities.replicas=0"
        , "-D ad.dw.http.port=9080"
        , "-D ad.dw.http.adminPort=9081"
        ]
    , extraVmOption = Nothing
    }
  , NodeConfig {
      nodeName = "indexer"
    , propertyOverrides = [
          "-D ad.admin.cluster.name=appdynamics-analytics-cluster"
        , "-D ad.admin.cluster.unicast.hosts.fallback=localhost:9300"
        , "-D ad.kafka.replication.factor=1"
        , "-D ad.dw.http.port=9070"
        , "-D ad.dw.http.adminPort=9071"
        ]
    , extraVmOption = Nothing
    }
  , NodeConfig {
      nodeName = "kafka-broker"
    , propertyOverrides = [
          "-D ad.kafka.replication.factor=1"
        , "-D ad.dw.http.port=9060"
        , "-D ad.dw.http.adminPort=9061"
        ]
    , extraVmOption = Nothing
    }
  , NodeConfig {
      nodeName = "zookeeper"
    , propertyOverrides = [
          "-D ad.dw.http.port=9040"
        , "-D ad.dw.http.adminPort=9041"
        ]
    , extraVmOption = Nothing
    }
  ]