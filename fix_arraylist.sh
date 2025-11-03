#!/bin/bash
# Fix ArrayList API for Zig 0.16-dev

# Pattern 1: ArrayList(X).init(allocator) -> ArrayList(X){}
find src/ai -name "*.zig" -type f -exec sed -i \
  -e 's/std\.ArrayList(\([^)]*\))\.init([^)]*)/std.ArrayList(\1){}/g' \
  -e 's/\.ArrayList(\([^)]*\))\.init([^)]*)/\.ArrayList(\1){}/g' \
  {} \;

# Pattern 2: .deinit() -> .deinit(allocator) - this needs manual review
# Pattern 3: .append(item) -> .append(allocator, item) - this needs manual review
# Pattern 4: .appendSlice(slice) -> .appendSlice(allocator, slice) - this needs manual review
# Pattern 5: .toOwnedSlice() -> .toOwnedSlice(allocator) - this needs manual review

echo "Phase 1 complete: Replaced .init(allocator) with {}"
echo "Manual fixes still needed for:"
echo "  - .deinit() -> .deinit(allocator)"
echo "  - .append(x) -> .append(allocator, x)"
echo "  - .appendSlice(x) -> .appendSlice(allocator, x)"
echo "  - .toOwnedSlice() -> .toOwnedSlice(allocator)"
