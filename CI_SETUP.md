# CI Setup for OutboundHTTPLogger Gem

This document describes the Continuous Integration (CI) setup for the OutboundHTTPLogger gem.

## Overview

The CI setup includes both local development tools and GitHub Actions workflows to ensure code quality and functionality.

## Local CI Script

### Usage

Run all CI checks locally:

```bash
./bin/ci
```

### What it checks

1. **Dependencies**: Installs gem dependencies
2. **Tests**: Runs the full test suite with Minitest
3. **RuboCop**: Runs code style and quality checks (non-blocking)
4. **Gem Building**: Validates that the gem can be built successfully
5. **Gemspec Validation**: Ensures the gemspec is valid
6. **TODO/FIXME Detection**: Scans for TODO/FIXME comments
7. **Security Audit**: Runs bundler-audit for dependency vulnerabilities

### Exit Codes

- `0`: All critical checks passed (tests and gem building)
- `1`: Critical checks failed (tests or gem building)

Note: RuboCop and security audit failures are non-blocking and won't cause the script to exit with an error code.

### Test Execution Strategy

**✅ Test isolation issues have been resolved!**

The gem now supports running all tests together with parallel execution for improved performance:

- **Parallel Testing**: Tests run in parallel using thread-based parallelization (8 threads by default)
- **Thread Safety**: All configuration and state management is thread-safe with proper isolation
- **Database Isolation**: Each test thread gets its own database connection from a properly sized pool
- **Clean State**: Comprehensive setup/teardown ensures no test interference

The test suite includes:
- All patch tests (`test/patches/*.rb`)
- Integration tests (`test/integration/*.rb`)
- Model tests (`test/models/*.rb`)
- Core functionality tests (`test/test_*.rb`)
- Edge case and isolation tests

**Excluded from main suite** (require special setup):
- `test/test_database_adapters.rb` (requires Rails environment)
- `test/test_recursion_detection.rb` (requires Rails.logger)

## GitHub Actions Workflow

### Trigger Conditions

The workflow runs on:
- Push to `develop` or `main` branches (when gem files change)
- Pull requests targeting `develop` or `main` branches (when gem files change)

### Jobs

#### 1. Test Job
- **Purpose**: Run the test suite with parallel execution
- **Ruby Version**: 3.4
- **Rails Version**: 7.2.0
- **Parallel Execution**: 8 threads (thread-based for optimal performance)
- **Steps**:
  - Checkout code
  - Set up Ruby environment
  - Install dependencies
  - Run tests with `bundle exec rake test` (all tests together)
  - Run RuboCop (non-blocking)

#### 2. Build Job
- **Purpose**: Validate gem can be built
- **Steps**:
  - Checkout code
  - Set up Ruby environment
  - Install dependencies
  - Build gem with `bundle exec rake build`
  - Upload gem artifact (retained for 7 days)

#### 3. Quality Job
- **Purpose**: Additional quality checks
- **Steps**:
  - Checkout code
  - Set up Ruby environment
  - Install dependencies
  - Validate gemspec
  - Check for TODO/FIXME comments (non-blocking)

#### 4. Security Job
- **Purpose**: Security vulnerability scanning
- **Steps**:
  - Checkout code
  - Set up Ruby environment
  - Install dependencies
  - Run bundler-audit (non-blocking)

#### 5. Summary Job
- **Purpose**: Aggregate results and provide summary
- **Depends on**: All other jobs
- **Behavior**:
  - Always runs (even if other jobs fail)
  - Creates a summary table of job results
  - Fails if critical jobs (test, build) fail
  - Succeeds if only quality/security jobs fail

## Configuration Files

### RuboCop Configuration

- **File**: `.rubocop.yml`
- **Inherits from**: Root project RuboCop configuration
- **Exclusions**:
  - `bin/**/*` (executable scripts)
  - `sig/**/*` (type signatures)
  - `lib/outbound_http_logger/generators/templates/**/*` (ERB templates)

### Test Configuration

- **Framework**: Minitest with spec-style syntax
- **Database**: In-memory SQLite for testing with connection pooling
- **Parallel Testing**: Thread-based with `minitest-parallel-db` for database isolation
- **Connection Pool**: Scales with worker count (3 connections per worker, minimum 15)
- **Mocking**: WebMock for HTTP request stubbing
- **Test Helper**: Comprehensive setup with configuration reset and strict isolation checks
- **Thread Safety**: Full thread-local configuration and state management

## Badge

The README includes a CI status badge:

```markdown
[![CI](https://github.com/getupgraded/outbound_http_logger/actions/workflows/outbound-http-logger-ci.yml/badge.svg)](https://github.com/getupgraded/outbound_http_logger/actions/workflows/outbound-http-logger-ci.yml)
```

## Troubleshooting

### Common Issues

1. **Test Failures**:
   - Check that configuration is properly reset between tests
   - Ensure WebMock stubs are correctly configured
   - Verify that patches are applied before tests run

2. **RuboCop Issues**:
   - Many issues are auto-correctable with `bundle exec rubocop --auto-correct`
   - Style issues are non-blocking in CI

3. **Gem Building Issues**:
   - Check gemspec for syntax errors
   - Ensure all required files are included in `spec.files`

4. **Dependency Conflicts**:
   - Remove duplicate gem specifications between Gemfile and gemspec
   - Use consistent version constraints

### Running Individual Checks

```bash
# Run tests only
bundle exec rake test

# Run RuboCop only
bundle exec rubocop . --config .rubocop.yml

# Build gem only
bundle exec rake build

# Security audit only
gem install bundler-audit
bundle-audit check --update
```

## Parallel Testing Implementation

### Thread-Based Approach

The gem uses thread-based parallel testing instead of process-based to avoid DRb serialization issues:

- **Worker Count**: Defaults to `Etc.nprocessors - 2` (configurable via `PARALLEL_WORKERS`)
- **Connection Pooling**: Automatically scales with worker count for optimal performance
- **Thread Safety**: All configuration and state management is thread-local
- **Isolation**: Strict test isolation with error detection for cleanup violations

### Performance Benefits

- **Faster Test Execution**: ~8x speedup with 8 threads on modern hardware
- **Resource Efficiency**: Shared memory space reduces overhead vs. process-based
- **Database Optimization**: In-memory SQLite with proper connection pooling

### Isolation Mechanisms

- **Configuration Reset**: Each test starts with clean global configuration
- **Thread-Local Cleanup**: Automatic clearing of thread-local data between tests
- **State Verification**: Optional strict isolation checks (`STRICT_TEST_ISOLATION=true`)
- **Database Isolation**: Separate connections and transaction handling per thread

## Future Improvements

- Consider adding code coverage reporting
- Add performance benchmarking
- Implement automated dependency updates
- Add integration tests with real HTTP libraries
