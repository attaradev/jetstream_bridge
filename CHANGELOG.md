# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [7.1.3] - 2026-02-13

### Fixed

- **Publish recovery for transient JetStream context loss** - `JetstreamBridge.publish` now catches `ConnectionNotEstablishedError`, performs a reconnect, and retries once so publish calls no longer fail immediately during brief JetStream context refresh windows.
- **Initialized-but-stale connection recovery** - Internal `connect_if_needed!` now validates that a JetStream context is actually available (not just that startup previously ran) and triggers reconnect when context refresh is pending or failed.

## [7.1.2] - 2026-02-11

### Fixed

- **Skip all JS.API calls when `auto_provision=false`** - `ensure_consumer!` and `auto_create_consumer_on_error` no longer issue `stream_info`, `consumer_info`, or `add_consumer` calls when `auto_provision=false`. This fixes failures in restricted NATS accounts where `$JS.API` permissions are not granted and the stream/consumer are pre-provisioned by an admin.

### Changed

- **Restricted permissions docs** - Added missing `$JS.ACK.{stream}.{consumer}.>` publish permissions to all permission examples. Without this permission, consumers cannot acknowledge messages and they are redelivered until `max_deliver` is exhausted.

## [7.1.1] - 2026-02-02

### Changed

- Fail-fast consumer provisioning: when running in push mode with `auto_provision=false`, the bridge now raises `ConsumerProvisioningError` instead of silently skipping consumer setup, preventing idle workers when the durable is missing.
- Permission-aware creation: consumer creation now surfaces `ConsumerProvisioningError` on permissions violations (pull or push mode), guiding operators to grant the minimal `$JS.API` rights or pre-provision the durable.

### Added

- New `ConsumerProvisioningError` topology error for clearer operator feedback when consumer setup cannot proceed.

## [7.1.0] - 2026-02-01

### Added

- **Auto-create consumer on subscription** - Consumers are now automatically created if they don't exist when subscribing, regardless of the `auto_provision` setting. This eliminates the need for manual consumer provisioning while `auto_provision` continues to control only stream topology creation.
- `SubscriptionManager#stream_exists?` - Public method to check if a stream exists.
- `SubscriptionManager#consumer_exists?` - Public method to check if a consumer exists in the stream.
- `SubscriptionManager#create_consumer_if_missing!` - Public method to create a consumer only if it doesn't already exist (race-condition safe). Raises `StreamNotFoundError` if the stream doesn't exist.

### Changed

- `ensure_consumer!` now always auto-creates the consumer if it doesn't exist. The `auto_provision` setting only controls stream topology (stream creation), not consumer creation.
- Consumer recovery automatically attempts to create the consumer when a "consumer not found" error is detected.
- **Stream must exist** - Auto-create consumer fails fast with `StreamNotFoundError` if the stream doesn't exist. Streams must be provisioned separately via `auto_provision=true` or manual provisioning.

## [7.0.0] - 2026-01-30

### Added

- Full Rails reference examples (non-restrictive and restrictive) with Docker Compose, provisioner service, and end-to-end test scripts.
- Architecture and API reference docs covering topology, consumer modes, and public surface.

### Changed

- Major refactor separating provisioning from runtime to support least-privilege deployments; `auto_provision=false` now avoids JetStream management APIs at runtime.
- Config helpers simplified bidirectional setup (`configure_bidirectional`, `setup_rails_lifecycle`) replacing verbose initializer boilerplate.
- Consumer pipeline hardened: push-consumer mode, safer signal handling, improved drain behavior, and pull subscription shim reliability.

### Fixed

- Provisioner keyword argument handling, generator load edge cases, and connection/consumer recovery during JetStream context refresh.

## [5.0.0] - 2026-01-30

### Added

- **Push consumer mode** for restricted NATS credentials — `consumer_mode: :push` with optional `delivery_subject`, no `$JS.API.*` permissions required, documented in the restricted permissions guide.
- **Reference examples**: full Rails apps for non-restrictive (auto-provisioning) and restrictive (least-privilege + provisioner) deployments with Docker Compose and end-to-end test scripts.
- **ConfigHelpers & docs**: helper to configure bidirectional sync in one call, Rails lifecycle helper, new Architecture/API docs describing topology and public surface.

### Changed

- **Provisioning flow** separated from runtime: when `auto_provision=false` runtime skips JetStream management APIs; provisioning handled via rake task/CLI with admin creds. Health/test_connection honor restricted mode.
- **Consumer reliability**: refactored subscription builder, trap-safe signal handling, push-consumer drain via `next_msg`, sturdier pull subscription shim, JetStream context refresh retries after reconnects.
- **Quality & coverage**: generator template tweaks, provisioner keyword fixes, and test suite expanded (~96% coverage) across provisioning, consumer, and connection lifecycle paths.

### Fixed

- Fixed TypeError/timeout handling in push consumer drain and process loop.
- Fixed Rails generator load edge case and provisioner keyword argument bugs.
- Guarded JetStream API calls when constants are private, preserving connection state during JetStream context refresh failures.

## [4.4.1] - 2026-01-16

### Fixed

- **Rails Generators** - Qualify Rails constants to avoid `JetstreamBridge::Rails::Generators` NameError during generator load

## [4.4.0] - 2025-11-24

### Changed

- **RTT Measurement** - Enhanced NATS round-trip time measurement with fallback support
  - Added automatic unit normalization (seconds to milliseconds) for RTT values
  - Implemented fallback RTT measurement using `flush` for NATS clients without native `rtt` method
  - Supports both nats-pure and other NATS client implementations
  - Better compatibility across different NATS client versions

- **Rails Integration** - Improved Rake task detection reliability
  - Changed from `defined?(::Rake)` check to `$PROGRAM_NAME` inspection
  - More reliable detection of Rake execution context
  - Prevents false positives when Rake is loaded but not executing

### Fixed

- **Test Coverage** - Comprehensive test suite improvements
  - Added complete test coverage for Rails integration lifecycle methods
  - Added tests for test helper matchers (`have_published`, `be_publish_success`, `be_publish_failure`)
  - Added tests for fixture builders (`sample_event`, `sample_events`, `event`)
  - Added test for RTT fallback behavior when client lacks `rtt` method
  - Added spec file for `bridge_helpers` module

## [4.3.0] - 2025-11-24

### Added

- **Connection Diagnostics** - Exposed reconnection error tracking for health checks
  - `last_reconnect_error` and `last_reconnect_error_at` now publicly accessible
  - Enables better monitoring and diagnostics of connection issues
  - Added test coverage for diagnostic accessor visibility

### Changed

- **Connection Lifecycle** - Improved topology management during startup
  - `startup!` now explicitly ensures topology is created during initialization
  - `connect_and_ensure_stream!` properly ensures topology after connecting
  - `fetch_stream_info` now ensures connection is established before querying
  - More reliable initialization sequence for non-Rails applications

- **Rails Integration** - Changed console autostart behavior
  - Rails console now autostarts JetStream Bridge by default (previously skipped)
  - Simplified autostart logic by removing console detection as skip condition
  - Autostart remains disabled only for rake tasks (unless forced with `JETSTREAM_BRIDGE_FORCE_AUTOSTART`)
  - Better developer experience in Rails console for immediate testing

- **Documentation** - Clarified connection initialization behavior
  - Added notes explaining that `configure` only sets options and does not connect
  - Documented when connection actually occurs (Rails: after initialization; non-Rails: call `startup!`)
  - Improved explanation of `lazy_connect` behavior in Rails environments
  - Added guidance for non-Rails applications to call `startup!` explicitly

### Fixed

- **Test Coverage** - Added missing test scenarios
  - Added tests for topology ensuring in `startup!` and `connect_and_ensure_stream!`
  - Added tests for connection initialization in `stream_info`
  - Updated Rails integration specs to reflect new console behavior

## [4.2.0] - 2025-11-24

### Added

- **Modular Code Organization** - Restructured codebase with dedicated modules
  - New `JetstreamBridge::Core` module for core utilities (connection, logging, model utils, helpers)
  - New `JetstreamBridge::Rails` module for Rails-specific integration
  - Improved separation of concerns and code discoverability
  - Better namespace organization for future extensibility

- **Enhanced Test Helpers** - Comprehensive testing utilities split into focused modules
  - `JetstreamBridge::TestHelpers::Fixtures` - Convenient fixture generation for events and messages
  - `JetstreamBridge::TestHelpers::IntegrationHelpers` - Full NATS message simulation for integration tests
  - `JetstreamBridge::TestHelpers::Matchers` - RSpec matchers for event publishing assertions
  - Improved test doubles with realistic NATS message structure
  - Better support for testing event-driven Rails applications

- **Getting Started Guide** - New comprehensive guide in `docs/GETTING_STARTED.md`
  - Quick installation and setup instructions
  - Publishing and consuming examples
  - Rails integration patterns
  - Links to advanced documentation

### Changed

- **Rails Integration** - Reorganized Rails-specific code
  - Moved from single `lib/jetstream_bridge/railtie.rb` to dedicated `lib/jetstream_bridge/rails/` directory
  - `JetstreamBridge::Rails::Railtie` - Rails lifecycle integration
  - `JetstreamBridge::Rails::Integration` - Autostart logic and Rails environment detection
  - Cleaner separation between gem core and Rails integration

- **Documentation** - Restructured README for clarity
  - Condensed README focusing on quick start and highlights
  - Moved detailed guides to dedicated docs directory
  - Improved navigation with links to specialized documentation
  - More concise examples and clearer feature descriptions

- **Gemspec** - Enhanced package configuration
  - Added `docs/**/*.md` to distributed files
  - Added `extra_rdoc_files` for better documentation
  - Updated description to emphasize production-readiness

### Fixed

- **Code Quality** - Resolved all RuboCop style violations
  - Fixed string literal consistency issues
  - Improved code formatting and indentation
  - Reduced complexity in conditional assignments
  - Updated RuboCop configuration for new file structure

## [4.1.0] - 2025-11-23

### Added

- **Enhanced Subject Validation** - Strengthened subject component validation for security
  - Validates against control characters, null bytes, tabs, and excessive spaces
  - Enforces maximum subject component length of 255 characters
  - Prevents injection attacks via malformed subject components
  - Provides clear error messages with invalid character details

- **Health Check Rate Limiting** - Prevents abuse of health check endpoint
  - Limits uncached health checks to once every 5 seconds per process
  - Cached health checks (30s TTL) bypass rate limit
  - Returns helpful error message with wait time when rate limit exceeded
  - Thread-safe implementation with mutex synchronization

- **Consumer Reconnection Backoff** - Exponential backoff for consumer recovery
  - Starts at 0.1s and doubles with each retry up to 30s maximum
  - Resets counter on successful reconnection
  - Logs detailed reconnection attempts with backoff timing
  - Prevents excessive NATS API calls during connection issues

- **OverlapGuard Performance Cache** - 60-second TTL cache for stream metadata
  - Reduces N+1 API calls when checking stream overlaps
  - Thread-safe cache implementation with mutex
  - Falls back to cached data on fetch errors
  - Includes `clear_cache!` method for testing

- **Consumer Memory Monitoring** - Health checks for long-running consumers
  - Logs health status every 10 minutes (iterations, memory, uptime)
  - Warns when memory usage exceeds 1GB
  - Suggests garbage collection when heap grows large (>100k live objects)
  - Cross-platform memory monitoring (Linux/macOS)

- **Production Deployment Guide** - Comprehensive documentation in docs/PRODUCTION.md
  - Database connection pool sizing guidelines
  - NATS HA configuration examples
  - Consumer tuning recommendations
  - Monitoring and alerting best practices
  - Kubernetes deployment examples with health probes
  - Security hardening recommendations
  - Performance optimization techniques

### Changed

- **Health Check API** - Added optional `skip_cache` parameter
  - `JetstreamBridge.health_check(skip_cache: true)` forces fresh check
  - Default behavior unchanged (uses 30s cache)
  - Rate limited when `skip_cache` is true

### Fixed

- **Test Suite** - Fixed test failures in OverlapGuard specs
  - Added cache clearing in test setup to prevent interference
  - All 1220 tests passing with 93.32% line coverage

## [4.0.4] - 2025-11-23

### Fixed

- **NATS Compatibility** - Fix connection failure with nats-pure 2.5.0
  - Handle both object-style and hash-style access for stream_info responses
  - Fixes "undefined method 'streams' for Hash" error during connection establishment
  - Adds compatibility checks using `respond_to?` for config and state attributes
  - Updated 4 files: jetstream_bridge.rb, topology/stream.rb, topology/overlap_guard.rb, debug_helper.rb
  - Maintains backward compatibility with older nats-pure versions

## [4.0.3] - 2025-11-23

### Added

- **Connection Validation** - Comprehensive NATS URL validation on initialization
  - Validates URL format, scheme (nats/nats+tls), host presence, and port range (1-65535)
  - Verifies NATS connection established after connect
  - Verifies JetStream availability with account info check
  - Helpful error messages for common misconfigurations
  - All validation errors include specific guidance for fixes

- **Connection Logging** - Detailed logging throughout connection lifecycle
  - Debug logs for URL validation progress and verification steps
  - Info logs for successful validation and JetStream stats (streams, consumers, memory, storage)
  - Error logs for all validation failures with specific details
  - Automatic credential sanitization in all log messages
  - Human-readable resource usage formatting (bytes to KB/MB/GB)

### Fixed

- **Health Check** - Fixed `healthy` field returning `nil` instead of `false` when disconnected
  - Changed `stream_info[:exists]` to `stream_info&.fetch(:exists, false)` for proper nil handling
  - Ensures boolean values always returned for monitoring systems

### Changed

- **Code Organization** - Moved all inline RuboCop rules to centralized `.rubocop.yml`
  - Removed inline comments from 5 files (logging.rb, model_utils.rb, inbox_event.rb, outbox_event.rb, inbox_message.rb)
  - Added exclusions to `.rubocop.yml` for metrics and naming rules
  - Cleaner codebase with all style exceptions in one location

## [4.0.2] - 2025-11-23

### Fixed

- **Stream Updates** - Prevent retention policy change errors (NATS error 10052)
  - Skip all stream updates when retention policy differs from expected 'workqueue'
  - Prevents "stream configuration update can not change retention policy to/from workqueue" error
  - Logs warning when stream has mismatched retention policy but skips update
  - Ensures compatibility with existing streams that have different retention policies

## [4.0.1] - 2025-11-23

### Fixed

- **Documentation** - Updated version references in README and YARD documentation
  - Installation instructions now reference version 4.0
  - Health check example output shows correct version
  - YARD documentation reflects current version

## [4.0.0] - 2025-11-23

### Breaking Changes

- **Per-app Dead Letter Queue (DLQ)** - DLQ subject pattern changed for better isolation
  - **Old pattern**: `{env}.sync.dlq` (shared across all apps)
  - **New pattern**: `{env}.{app_name}.sync.dlq` (isolated per app)
  - **Example**: `production.api.sync.dlq` instead of `production.sync.dlq`

### Benefits

- **Isolation**: Failed messages from different services don't mix
- **Easier Monitoring**: Track DLQ metrics per service
- **Simpler Debugging**: Identify which service is having issues
- **Independent Processing**: Each team can manage their own DLQ consumer

### Migration Guide

1. **Drain existing DLQ**: Process or archive messages from the old shared DLQ (`{env}.sync.dlq`)
2. **Deploy update**: Each app will automatically create its own DLQ subject on next deployment
3. **Update monitoring**: Adjust dashboards to track per-app DLQ subjects (`{env}.{app_name}.sync.dlq`)
4. **Update DLQ consumers**: Update DLQ consumer configuration to use app-specific subjects

### Documentation

- **Enhanced README** - Comprehensive documentation improvements
  - Fixed consumer handler signature (single `event` parameter, not three)
  - Added complete DLQ consumer examples with Rake task
  - Added thread-safety documentation for Publisher
  - Updated all subject pattern references
  - Added DLQ monitoring examples
- **YARD documentation** - Professional API documentation
  - Added `.yardopts` configuration for consistent doc generation
  - 60%+ documentation coverage across public APIs
  - Configured RubyDoc.info integration
  - Added Rake tasks for generating docs (`rake yard`)

### Code Quality

- **RuboCop compliance** - Zero offenses across entire codebase
  - Configured appropriate exclusions for test files and acceptable patterns
  - Fixed all auto-correctable style violations
  - Added clear comments for non-correctable patterns

## [3.0.0] - 2025-11-23

### Added

#### Production-Ready Features

- **Health checks** - Comprehensive health check API via `JetstreamBridge.health_check`
  - NATS connection status monitoring
  - Stream existence and subject verification
  - Configuration validation
  - Returns structured health data for monitoring systems
- **Health check generator** - Rails generator for creating health check endpoints
  - `rails g jetstream_bridge:health_check` creates controller and route
  - Automatic route injection into `config/routes.rb`
  - Returns appropriate HTTP status codes (200/503)
- **Auto-reconnection** - Automatic recovery from connection failures
  - Exponential backoff retry strategy
  - Configurable retry limits and delays
  - Connection state tracking with timestamps
- **Connection factory** - Centralized connection management
  - Singleton pattern for connection handling
  - Thread-safe connection access
  - Public `connected?` and `connected_at` accessors

#### Error Handling

- **Comprehensive error hierarchy** - Well-organized exception classes
  - `ConfigurationError` - Base for configuration issues
  - `ConnectionError` - Base for connection problems
  - `PublishError` - Base for publishing failures
  - `ConsumerError` - Base for consumption issues
  - `TopologyError` - Base for stream/subject topology errors
  - `DlqError` - Base for dead-letter queue operations
  - All inherit from `JetstreamBridge::Error`

#### Developer Experience

- **Debug helper** - Comprehensive debugging utility via `JetstreamBridge::DebugHelper`
  - Configuration dump
  - Connection status
  - Stream information
  - Subject validation
  - Model availability checks
- **Rake tasks** - CLI tools for operations
  - `rake jetstream_bridge:health` - Check health and connection status
  - `rake jetstream_bridge:validate` - Validate configuration
  - `rake jetstream_bridge:test_connection` - Test NATS connection
  - `rake jetstream_bridge:debug` - Show comprehensive debug information
- **Value objects** - Type-safe domain models
  - `EventEnvelope` - Structured event representation
  - `Subject` - Subject pattern validation and parsing

#### Testing & Quality

- **Comprehensive test suite** - 248 RSpec tests covering all core functionality
  - Configuration validation specs
  - Connection factory specs with edge cases (48 new tests added)
    - Server URL normalization (single, comma-separated, arrays, whitespace)
    - Authentication options (user, pass, token)
    - NATS URL validation (nil, empty, whitespace-only)
    - JetStream context creation and nc accessor
  - Event envelope specs with full coverage (18 new tests added)
    - Initialization edge cases (trace ID, Time objects, resource ID extraction)
    - Hash serialization and deserialization
    - Deep immutability validation
    - Equality and hashing behavior
    - Error handling for invalid timestamps
  - Retry strategy specs
  - Model specs
  - Error hierarchy specs
- **Subject validation** - Prevents NATS wildcards in configuration
  - Validates `env`, `app_name`, and `destination_app` don't contain `.`, `*`, or `>`
  - Clear error messages for invalid subjects
- **Bug fixes in implementation** - Fixed `EventEnvelope.from_h` to properly handle deserialization
  - Removed invalid `schema_version` parameter
  - Added missing `resource_id` parameter

### Changed

#### Architecture Improvements

- **Consolidated configuration** - Streamlined `Config` class
  - Removed redundant configuration classes
  - Centralized validation logic
  - Better default values
- **Enhanced generator templates** - Improved initializer template
  - Better documentation and comments
  - Organized sections (Connection, Consumer, Reliability, Models, Logging)
  - Clear indication of required vs optional settings
- **Simplified consumer initialization** - Cleaner API
  - Sensible defaults for `durable_name` and `batch_size`
  - Removed unnecessary configuration classes
- **Better logging** - Configurable logger with sensible defaults
  - Respects `config.logger` setting
  - Falls back to `Rails.logger` in Rails apps
  - Uses `STDOUT` logger otherwise

#### Bug Fixes

- **Fixed duration parsing** - Correct integer conversion for duration strings
  - Handles edge cases properly
  - Added comprehensive tests
- **Fixed subject format** - Corrected DLQ subject pattern
  - Changed from `{env}.data.sync.dlq` to `{env}.sync.dlq`
  - Updated all documentation
- **Repository improvements**
  - Transaction safety for all database operations
  - Pessimistic locking for outbox operations
  - Race condition protection
  - Better error handling and logging

### Refactored

- **Consumer architecture** - Consolidated consumer support classes
  - Merged related functionality
  - Reduced file count
  - Clearer separation of concerns
- **Model handling** - Streamlined inbox/outbox models
  - Graceful column detection without connection boot
  - Better validation guards
  - Simplified attribute handling
- **JSON handling** - Switched to Oj for performance
  - Faster JSON parsing/serialization
  - Consistent JSON handling across the gem
- **Topology management** - Enhanced stream and subject handling
  - Improved overlap detection
  - Better error messages
  - More robust subject matching

### Documentation Updates

- **Updated README** - Comprehensive documentation updates
  - Added section for Rails generators and rake tasks
  - Documented all new health check features
  - Fixed incorrect subject patterns
  - Added operations guide
  - Improved getting started section
- **Enhanced code comments** - Better inline documentation
  - YARD-style documentation for public APIs
  - Clear explanations of complex logic
  - Usage examples in comments
- **Generator improvements** - Better user guidance
  - Clear success messages
  - Usage instructions after generation
  - Example configurations

### Internal

- **Removed deprecated code**
  - Cleaned up unused classes and methods
  - Removed `BackoffStrategy` (consolidated into retry strategy)
  - Removed `ConsumerConfig` (merged into main config)
  - Removed `MessageContext` (functionality integrated)

## [2.10.0] and earlier

See git history for changes in earlier versions.
