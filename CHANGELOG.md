# Changelog

## 0.0.2

### Code Quality Improvements
- ✅ Extract common patch behavior into shared module to eliminate duplication across Net::HTTP, Faraday, and HTTParty patches
- ✅ Replace magic numbers with named constants for better maintainability (max_body_size, max_recursion_depth, connection pool settings)
- ✅ Refactor URL filtering logic into focused, separate methods (should_log_url? now uses logging_enabled_for_url?, valid_url?, url_excluded?)
- ✅ Standardize error handling patterns across the codebase with ErrorHandling module that ensures logging errors never interrupt parent application HTTP traffic

### Documentation Enhancements
- ✅ Add comprehensive YARD documentation for all public methods with examples and parameter descriptions
- ✅ Update and verify all README examples work with current implementation (comprehensive test suite added)
- ✅ Add comprehensive performance considerations and best practices guide to README
- Document thread-based logic for parallel test support

### Testing Improvements
- ✅ Add comprehensive edge case testing for concurrent access and extreme inputs
- ✅ Fix test isolation issues to allow running full test suite together with parallel execution (8 threads)
- ✅ Implement thread-based parallel testing with proper database isolation and connection pooling
- ✅ Add comprehensive integration tests for Rails features (generator, rake tasks, railtie)
- ✅ Include database adapter tests in CI suite with separate task for optimal performance

### Dependency Management
- ✅ Remove unused development dependencies (rubocop-md) and relax ActiveRecord/ActiveSupport constraints to >= 7.0.0
- ✅ Add graceful handling for optional HTTP libraries with improved error handling and logging

### Documentation
- ✅ Document thread-based logic for parallel testing with comprehensive THREAD_SAFETY.md and updated AGENTS.md

### Architecture Enhancements
- Standardize database adapter interface and error handling
- Add structured logging, metrics collection, and debugging tools
- Implement granular patch control for selective enable/disable
- Add log rotation, cleanup strategies, and memory management features

### Summary
This release represents a major milestone in the OutboundHTTPLogger gem development, bringing it to production-ready status with comprehensive documentation, testing, and robust error handling. The gem now includes extensive edge case coverage, detailed performance guidance for production deployments, and comprehensive YARD documentation for all public methods.

## 0.0.1

* Initial release.
