# Analytics Cluster Startup Script

This is a "launcher" script to avoid manually performing repetitive tasks when you want to 
bring up a copy of our SaaS cluster locally. What this does is:
- call to gradle to build / zip the source code
- call unzip multiple times, once for each "node" type we want to launch
- start up each node type with property overrides corresponding to the config provided

Another thing this does in order to hopefully save the developer some time is that it wraps all the sub-processes it 
spawns with some "finally" logic. Some of the nodes don't die very quickly when told to shut down, so this script has 
some custom ctrl-c handling that does a "kill -9" on nodes that might try to hang onto life.

# Installation
This project uses haskell, stack, and haskell's shell scripting library, "turtle". So to set this up, you'll need to 
install those:
- install stack: `curl -sSL https://get.haskellstack.org/ | sh`
- go to project root, run `stack build` (this will probably take a while the first time)

Should be good to go, once it has downloaded everything you can run the script with
- `./src/Main.hs -p plans/default-saas.json` for saas mode (default is one of each node)
- `./src/Main.hs -p plans/default-on-prem.json` for on-prem mode (default is a single node)
- or use these as guidelines for making your own deployment strategy. 

Once it's up, stop it with ctrl-c. Also note that you need `ANALYTICS_HOME` set before running this. Call 
`./src/Main.hs -h` to see all possible arguments.

If you want to actually change any of the Haskell code, you probably want to install the IntelliJ-Haskell plugin and then
run `stack build intero` to install the tool the plugin uses. 

# How-To

## Start multiple nodes of the same type

If you want to launch multiple nodes of the same type, for instance 3x API nodes
instead of 1, you can add the optional parameter "dirName" to the json plan. In the 
presence of this parameter, the script will launch the node with property file name 
from "nodeName" but the directory it lives in will be "dirName". Note that if you 
do this, you need to manually inspect the properties for each node to make sure 
none clash, i.e. that the ports, debugOption, etc are different. See `plans/saas-multi-node.json`
for an example.

## Restarting nodes

By default, the launcher will fail everything if one node stops, mostly to provide
fast feedback in case there's something wrong with one node's startup. You can
disable this behavior with the `-n|--no-kill-all` flag, which you can use to test
out scenarios where you need to restart some nodes. Note that shortly after starting
Elasticsearch, the script will spit out the command it's using to start all nodes like the following, though it would have
$ANALYTICS_HOME expanded to whatever it is on your system:
```
sh $ANALYTICS_HOME/analytics-processor/build/distributions/api/analytics-processor/bin/analytics-processor.sh start -p $ANALYTICS_HOME/analytics-processor/build/distributions/api/analytics-processor/conf/analytics-api.properties -D ad.dw.log.path=/Users/christian.henry/appdynamics/analytics-codebase/analytics/analytics-processor/build/distributions/api/analytics-processor/logs -D ad.admin.cluster.name=appdynamics-analytics-cluster -D ad.admin.cluster.unicast.hosts.fallback=localhost:9300 -D ad.metric.processor.clients.fallback=appdynamics-analytics-cluster=localhost:9020 -D ad.es.event.index.replicas=0 -D ad.es.metadata.replicas=0 -D ad.es.metadata.entities.replicas=0 -D ad.dw.http.port=9080 -D ad.dw.http.adminPort=9081 -D ad.jf.http.port=9030 -D ad.jvm.heap.min=256m -D ad.jvm.heap.max=256m -D ad.metric.processor.enabled.accounts=*
```
so if you wanted to restart a node, you would first stop it:
```
sh $ANALYTICS_HOME/analytics-processor/build/distributions/api/analytics-processor/bin/analytics-processor.sh stop
```
then paste in the above start command to bring it back up.