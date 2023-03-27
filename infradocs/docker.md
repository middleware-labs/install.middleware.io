## Supported Machines

We have created docker distributions using, 
All the OS that supports docker should also support our docker based agent.

This is applicable on both x86 & ARM based machines.

## Current Technical Approach

In order to collect host level details, our docker agent works on host network mdde.

For log reading, the docker agent uses volume binding.


## Roadmap

1. Current docker installation bash script works well with Linux + Mac machines. We will be making this script adaptable for Windows machines as well.
