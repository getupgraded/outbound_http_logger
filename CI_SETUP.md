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

Due to test interference issues when running all tests together via `rake test`, both the local CI script and GitHub Actions workflow run tests individually by file:

- `test/patches/test_net_http_patch.rb`
- `test/concerns/test_outbound_logging.rb`
- `test/integration/test_loggable_integration.rb`
- `test/models/test_outbound_request_log.rb`
- `test/test_outbound_http_logger.rb`

This ensures reliable test execution and avoids global state interference between test files.

## GitHub Actions Workflow

### Trigger Conditions

The workflow runs on:
- Push to `develop` or `main` branches (when gem files change)
- Pull requests targeting `develop` or `main` branches (when gem files change)

### Jobs

#### 1. Test Job
- **Purpose**: Run the test suite
- **Ruby Version**: 3.4
- **Rails Version**: 7.2.0
- **Steps**:
  - Checkout code
  - Set up Ruby environment
  - Install dependencies
  - Run tests with `bundle exec rake test`
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
- **Database**: In-memory SQLite for testing
- **Mocking**: WebMock for HTTP request stubbing
- **Test Helper**: Comprehensive setup with configuration reset between tests

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

## Future Improvements

- Consider adding code coverage reporting
- Add performance benchmarking
- Implement automated dependency updates
- Add integration tests with real HTTP libraries
