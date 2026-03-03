# Deployment Guide

> **TODO**: This guide is under development.

## Overview

This guide covers deploying Malla applications to production, including configuration, monitoring, and platform-specific considerations.

## Topics to Cover

### Release Configuration
- Mix releases for Malla applications
- Environment-specific configuration
- Release configuration with `config/runtime.exs`
- Cookie management and security

### Kubernetes Deployment
- StatefulSet vs Deployment strategies
- Headless services for discovery
- Pod DNS configuration
- Health checks (liveness/readiness probes)
- Resource limits and requests
- Horizontal Pod Autoscaler considerations
- Complete Kubernetes manifests example

### Docker
- Dockerfile best practices for Malla
- Docker Compose for local testing
- Multi-stage builds
- Health checks in containers

### Networking
- Firewall configuration
- EPMD port configuration
- Distribution port ranges
- Load balancer configuration
- TLS for distribution (security)

### Monitoring and Observability
- Telemetry setup
- Prometheus metrics integration
- Distributed tracing backends (OpenTelemetry)
- Log aggregation (ELK, Loki, etc.)
- Alert patterns

### High Availability
- Node redundancy strategies
- Service placement strategies
- Graceful shutdown patterns
- Zero-downtime deployments
- Blue-green deployments
- Rolling updates

### Cloud Platforms
- AWS ECS/EKS specifics
- Google Cloud GKE specifics
- Azure AKS specifics
- Fly.io deployment patterns

## Related Guides

- [Cluster Setup](08-distribution/01-cluster-setup.md)
- [Configuration](07-configuration.md)
- [Tracing](09-observability/01-tracing.md)
