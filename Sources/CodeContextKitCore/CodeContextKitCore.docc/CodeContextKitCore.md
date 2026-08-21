# ``CodeContextKitCore``

The foundational engine for architectural code analysis and surgical context packing.

## Overview

CodeContextKitCore provides the base types, utilities, and protocols used across the CodeContextKit ecosystem. It is designed to be lightweight, thread-safe, and optimized for high-performance symbol extraction and token estimation. Outlines and symbol dumps fail closed above shared span limits rather than emitting a whole type body.

## Topics

### Core Types
- ``SymbolRecord``
- ``SymbolSpanLimits``
- ``Config``

### Outlines
- ``OutlineOptions``
- ``OutlineAssembler``
- ``OutlineRendering``

### Index freshness
- ``IndexStamp``
- ``IndexFreshness``

### Performance Utilities
- ``TokenEstimator``
- ``FileHasher``

### Protocols
- ``CodeSplitter``
