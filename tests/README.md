# Tests

The test suite will cover:

- configuration and schema validation;
- subscriber uniqueness and cross-component consistency;
- container and Helm artifact validation;
- unit tests for automation and reporting;
- single-UE and multi-UE integration;
- differentiated DNN or slice behavior;
- observability and alert behavior;
- performance methodology;
- controlled failure and recovery;
- cleanup and repeatability.

Tests that require privileged networking must be clearly separated from tests
safe for hosted Continuous Integration runners.
