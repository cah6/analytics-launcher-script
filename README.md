# Analytics Cluster Startup Script

This is a "launcher" script I made for work, mostly to avoid manually performing repetitive tasks for when I want to bring up a copy of our SaaS cluster locally. What this does is:
- call to gradle to build / zip the source code
- call unzip multiple times, once for each "node" type we want to launch
- start up each node type with property overrides corresponding to the config provided

Another thing this does in order to hopefully save the developer some time is that it wraps all the sub-processes it spawns with some "finally" logic. Some of the nodes don't die very quickly when told to shut down, so this script has some custom ctrl-c handling that does a "kill -9" on nodes that might try to hang onto life.

# Installation
This project uses haskell, stack, and haskell's shell scripting library, "turtle". So to set this up, you'll need to install those:
- install stack: `curl -sSL https://get.haskellstack.org/ | sh`
- go to project root, run `stack build` (this will probably take a while the first time)

Should be good to go, once it has downloaded everything you can run the script with
`./src/Main.hs`
and stop it with ctrl-c. 