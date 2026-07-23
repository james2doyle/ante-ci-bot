---
name: review
description: Review code changes for bugs, security issues, and style.
argument-hint: <path>
---

Review the code at $ARGUMENTS for bugs, security vulnerabilities, style issues, and missing error handling.

Here is a simple example of things to look for:

- spelling errors (in source code and comments)
- odd formatting (unnecessary line breaks, missing spaces)
- confusing variable names (single-letters in unconventional places, same name used multiple times, name that doesn’t match use case)
- repeated code (reusing the same code blocks instead of a helper function)
- logical errors (race conditions, accessing undefined, accessing null values)
- bugs (cases where code will not work as intended)
- unhandled errors (cases where an error could occur but not be caught or handled)

Based on the coding language being used, tailor this list to follow common conventions in that language.
