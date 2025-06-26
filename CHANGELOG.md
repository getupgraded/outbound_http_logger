# Changelog

## 0.0.2 (Unreleased)

### Code Quality Improvements
- ✅ Extract common patch behavior into shared module to eliminate duplication across Net::HTTP, Faraday, and HTTParty patches
- ✅ Replace magic numbers with named constants for better maintainability (max_body_size, max_recursion_depth, connection pool settings)
- ✅ Refactor URL filtering logic into focused, separate methods (should_log_url? now uses logging_enabled_for_url?, valid_url?, url_excluded?)
- ✅ Standardize error handling patterns across the codebase with ErrorHandling module that ensures logging errors never interrupt parent application HTTP traffic

### Documentation Enhancements
- ✅ Add comprehensive YARD documentation for all public methods with examples and parameter descriptions
- ✅ Update and verify all README examples work with current implementation (comprehensive test suite added)
- Add performance considerations and best practices guide
- Document thread-based logic for parallel test support

### Testing Improvements
- Add comprehensive edge case testing for concurrent access and extreme inputs
- Fix test isolation issues to allow running full test suite together
- Add integration tests for Rails features (generator, rake tasks, railtie)
- Include database adapter tests in main CI suite

### Dependency Management
- Audit and remove unused development dependencies
- Test and relax version constraints where possible
- Add graceful handling for optional HTTP libraries

### Architecture Enhancements
- Standardize database adapter interface and error handling
- Add structured logging, metrics collection, and debugging tools
- Implement granular patch control for selective enable/disable
- Add log rotation, cleanup strategies, and memory management features

## 0.0.1

* Initial release.
