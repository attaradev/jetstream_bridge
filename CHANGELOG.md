# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
