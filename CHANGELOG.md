# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [4.5.0] - 2026-01-22

### Added

- Dedicated `HealthChecker` service for comprehensive health monitoring
- `ConsumerHealthMonitor` for long-running consumer health tracking
- Stream name configuration now required (no more auto-generated defaults)

### Changed

- Refactored architecture with `Facade` pattern for cleaner API delegation
- Consolidated connection management into `ConnectionManager`
- Extracted health checking logic from connection layer into dedicated service
- Simplified documentation focusing on library features over implementation details

### Removed

- Removed `Connection` (refactored to `ConnectionManager`)
- Removed `BridgeHelpers` module (functionality distributed to appropriate layers)
- Removed auto-generated stream names (explicit configuration required)

## [4.4.1] - 2026-01-16

### Fixed

- Fixed Rails generator constant qualification to prevent NameError during load

## [4.4.0] - 2025-11-24

### Changed

- Enhanced NATS round-trip time measurement with automatic fallback for clients without native `rtt` method
- Improved Rails Rake task detection using `$PROGRAM_NAME` inspection

### Fixed

- Expanded test coverage for Rails integration and test helpers

## [4.3.0] - 2025-11-24

### Added

- Exposed reconnection error tracking via `last_reconnect_error` and `last_reconnect_error_at` for better diagnostics

### Changed

- Improved topology management during startup and connection initialization
- Rails console now autostarts JetStream Bridge by default (autostart remains disabled for rake tasks)
- Updated documentation to clarify connection initialization behavior

### Fixed

- Expanded test coverage for topology management and Rails integration

## [4.2.0] - 2025-11-24

### Added

- Restructured codebase with `JetstreamBridge::Core` and `JetstreamBridge::Rails` modules
- Enhanced test helpers with fixtures, integration helpers, and RSpec matchers
- New Getting Started guide in `docs/GETTING_STARTED.md`

### Changed

- Reorganized Rails integration code into dedicated directory structure
- Restructured README for clarity with focus on quick start
- Enhanced gemspec with documentation files

### Fixed

- Resolved all RuboCop style violations

## [4.1.0] - 2025-11-23

### Added

- Enhanced subject validation to prevent injection attacks
- Health check rate limiting (1 uncached request per 5 seconds)
- Exponential backoff for consumer reconnection (0.1s to 30s)
- 60-second TTL cache for OverlapGuard stream metadata
- Consumer memory monitoring with automatic health logging
- Production deployment guide in `docs/PRODUCTION.md`

### Changed

- Added `skip_cache` parameter to health check API

### Fixed

- Fixed OverlapGuard test failures with proper cache clearing

## [4.0.4] - 2025-11-23

### Fixed

- Fixed nats-pure 2.5.0 compatibility with hash-style stream_info responses

## [4.0.3] - 2025-11-23

### Added

- Comprehensive NATS URL validation on initialization
- Detailed connection lifecycle logging with credential sanitization

### Fixed

- Fixed health check returning `nil` instead of `false` when disconnected

### Changed

- Moved inline RuboCop rules to centralized `.rubocop.yml`

## [4.0.2] - 2025-11-23

### Fixed

- Prevented retention policy change errors by skipping updates when policy differs

## [4.0.1] - 2025-11-23

### Fixed

- Updated version references in documentation

## [4.0.0] - 2025-11-23

### Breaking Changes

- Changed DLQ subject pattern from `{env}.sync.dlq` (shared) to `{env}.{app_name}.sync.dlq` (per-app) for better isolation and monitoring

### Migration Guide

1. Drain existing DLQ messages from `{env}.sync.dlq`
2. Deploy update (each app creates its own DLQ subject automatically)
3. Update monitoring dashboards to track per-app DLQ subjects
4. Update DLQ consumer configuration

### Changed

- Enhanced README with corrected handler signatures and DLQ examples
- Added YARD documentation with 60%+ API coverage
- Achieved RuboCop compliance across entire codebase

## [3.0.0] - 2025-11-23

### Added

- Comprehensive health check API and Rails generator for monitoring endpoints
- Auto-reconnection with exponential backoff and connection state tracking
- Centralized connection factory with thread-safe access
- Well-organized error hierarchy with specific exception classes
- Debug helper utility with configuration and connection diagnostics
- Rake tasks for health checks, validation, and connection testing
- Type-safe value objects (EventEnvelope, Subject)
- Comprehensive test suite with 248+ RSpec tests
- Subject validation to prevent NATS wildcards

### Changed

- Consolidated configuration with streamlined Config class
- Enhanced generator templates with better documentation
- Simplified consumer initialization with sensible defaults
- Improved logging with configurable logger and fallbacks
- Switched to Oj for JSON handling performance
- Enhanced topology management with better overlap detection
- Updated README with generators, rake tasks, and operations guide

### Fixed

- Fixed duration parsing for edge cases
- Corrected DLQ subject pattern
- Improved repository transaction safety and locking
- Fixed EventEnvelope deserialization

### Refactored

- Consolidated consumer architecture
- Streamlined inbox/outbox model handling
- Removed deprecated code (BackoffStrategy, ConsumerConfig, MessageContext)

## [2.10.0] and earlier

See git history for changes in earlier versions.
