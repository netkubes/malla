# Troubleshooting Guide

> **TODO**: This guide is under development.

## Overview

This guide provides solutions to common issues when working with Malla services and distributed systems.

## Topics to Cover

### Service Discovery Issues
- Services not discovering each other
- Nodes not connecting
- Virtual modules not being created

### Callback Chain Problems
- Callbacks not executing in expected order
- Chain stopping unexpectedly
- Arguments not being passed correctly

### Configuration Issues
- Configuration not being applied
- Config layers not merging correctly
- Environment-specific config problems

### Plugin Issues
- Plugin dependency resolution errors
- Circular dependencies
- Optional dependencies not working
- Plugin groups ordering problems

### Distribution Issues
- Network connectivity problems
- Remote calls failing
- Timeout issues
- Failover not working

### Performance Issues
- Slow service startup
- High latency remote calls
- ETS storage bottlenecks
- Memory usage problems

### Debugging Techniques
- Debugging distributed traces
- Using observer for cluster inspection
- Enabling debug logging
- Common debugging patterns

## Related Guides

- [Cluster Setup](08-distribution/01-cluster-setup.md)
- [Service Discovery](08-distribution/02-service-discovery.md)
- [Remote Calls](08-distribution/03-remote-calls.md)
