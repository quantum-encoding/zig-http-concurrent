# Zig 0.13 to 0.16 Migration Guide

## Critical API Changes That Will Break Your Code

This guide documents the major breaking changes between Zig 0.13 and 0.16 that you WILL encounter when upgrading. These are not theoretical - these are battle-tested findings from migrating production code.

---

## 1. ArrayList API - COMPLETELY CHANGED

### The Problem
`ArrayList` no longer has an `.init()` method and no longer stores the allocator internally. This is the #1 breaking change that will hit every Zig project.

### Old (Zig 0.13 and earlier)
```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();

try list.append('H');
try list.appendSlice("ello");
list.items[0] = 'J';
```

### New (Zig 0.16)
```zig
var list = std.ArrayList(u8).empty;
defer list.deinit(allocator);  // Note: allocator required!

try list.append(allocator, 'H');  // Note: allocator as first param!
try list.appendSlice(allocator, "ello");
list.items[0] = 'J';  // This still works the same
```

### Migration Pattern
```zig
// WRONG - This will NOT compile in 0.16:
var list = std.ArrayList(u8).init(allocator);

// RIGHT - Use this instead:
var list = std.ArrayList(u8).empty;

// For capacity initialization:
var list = try std.ArrayList(u8).initCapacity(allocator, 100);
// becomes:
var list = std.ArrayList(u8).empty;
try list.ensureTotalCapacity(allocator, 100);
```

### Common Error Messages
```
error: struct 'array_list.Aligned(T,null)' has no member named 'init'
error: no field named 'allocator' in struct 'array_list.Aligned(T,null)'
```

---

## 2. I/O System - COMPLETE REDESIGN

### The Problem
The entire I/O system has been redesigned. `std.io` is now `std.Io` (capital I), and the stream APIs are completely different.

### Old (Zig 0.13)
```zig
var stream = std.io.fixedBufferStream(buffer);
var reader = stream.reader();
const bytes_read = try reader.read(&temp_buffer);
```

### New (Zig 0.16)
```zig
var reader = std.Io.Reader.fixed(buffer);
const bytes_read = try reader.readSliceShort(&temp_buffer);
```

### Key Changes:
- `std.io` → `std.Io` (capital I)
- No more `fixedBufferStream`
- `Reader.fixed()` creates a reader from a byte slice
- `read()` → `readSliceShort()` or `readSliceAll()`
- Different error sets (no `error.EndOfStream` in `ShortError`)

---

## 3. HTTP Client Response Headers

### The Problem
HTTP response headers are no longer directly accessible in the response structure.

### Old (Zig 0.13)
```zig
const response = try req.receiveHead(&.{});
for (response.head.headers.list.items) |header| {
    if (std.mem.eql(u8, header.name, "Content-Type")) {
        // process header
    }
}
```

### New (Zig 0.16)
```zig
const response = try req.receiveHead(&.{});
// Headers are NOT available in response.head
// You need to handle this differently or skip header processing
```

---

## 4. Gzip/Compression Changes

### The Problem
Gzip is no longer a separate module. It's part of the flate module with container types.

### Old (Zig 0.13)
```zig
var decompressor = std.compress.gzip.decompressor(stream.reader());
```

### New (Zig 0.16)
```zig
var input_reader = std.Io.Reader.fixed(compressed_data);
const buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
var decompress = std.compress.flate.Decompress.init(&input_reader, .gzip, buffer);

// Read decompressed data
var result = std.ArrayList(u8).empty;
defer result.deinit(allocator);

var temp: [4096]u8 = undefined;
while (true) {
    const n = try decompress.reader.readSliceShort(&temp);
    if (n == 0) break;
    try result.appendSlice(allocator, temp[0..n]);
}
```

---

## 5. Build System (build.zig)

### The Problem
The build API has subtle changes that cause cryptic errors.

### Key Changes:
- For Zig 0.16.0-dev versions, `addExecutable` still uses `root_source_file`
- Module system works the same but be careful with field names
- `build.zig.zon` format is very strict about field types

### Working Pattern (Zig 0.16)
```zig
const exe = b.addExecutable(.{
    .name = "myapp",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

---

## 6. Common Compilation Errors and Solutions

### Error: "no member named 'init'"
**Cause**: ArrayList API change
**Solution**: Replace `.init(allocator)` with `.empty`

### Error: "no field named 'allocator'"
**Cause**: ArrayList no longer stores allocator
**Solution**: Pass allocator to all methods

### Error: "expected type 'error{ReadFailed}', found 'error{EndOfStream}'"
**Cause**: I/O error sets have changed
**Solution**: Handle end-of-stream by checking return value (n == 0) instead of catching error

### Error: "root source file struct 'std' has no member named 'io'"
**Cause**: I/O module renamed
**Solution**: Use `std.Io` (capital I) instead of `std.io`

### Error: "no field named 'headers' in struct 'http.Client.Response.Head'"
**Cause**: HTTP client API redesign
**Solution**: Headers need different handling or skip header processing

---

## 7. Quick Reference Cheat Sheet

| Operation | Zig 0.13 | Zig 0.16 |
|-----------|----------|----------|
| Create ArrayList | `ArrayList(T).init(allocator)` | `ArrayList(T).empty` |
| Destroy ArrayList | `list.deinit()` | `list.deinit(allocator)` |
| Append to ArrayList | `list.append(item)` | `list.append(allocator, item)` |
| Append slice | `list.appendSlice(slice)` | `list.appendSlice(allocator, slice)` |
| Fixed buffer reader | `io.fixedBufferStream(buf).reader()` | `Io.Reader.fixed(buf)` |
| Read from reader | `reader.read(&buf)` | `reader.readSliceShort(&buf)` |
| I/O module | `std.io` | `std.Io` |
| Gzip decompress | `compress.gzip.decompressor()` | `compress.flate.Decompress.init(..., .gzip, ...)` |

---

## 8. Testing Your Migration

Create this test file to verify your environment:

```zig
// test_zig_version.zig
const std = @import("std");

pub fn main() !void {
    // Test 1: ArrayList
    var list = std.ArrayList(u8).empty;
    defer list.deinit(std.heap.page_allocator);
    try list.append(std.heap.page_allocator, 'Z');

    // Test 2: I/O
    const data = "Hello";
    var reader = std.Io.Reader.fixed(data);

    std.debug.print("✅ Zig 0.16 APIs working!\n", .{});
}
```

Run with: `zig run test_zig_version.zig`

---

## 9. Pro Tips from Production Migration

1. **Don't trust old documentation or examples** - Most online Zig content is for 0.11 or 0.13
2. **Check the actual struct definitions** - Use `grep` in `/usr/local/zig*/lib/std/` to find the real API
3. **ArrayList is everywhere** - Fix this first, it touches everything
4. **Allocator passing is explicit now** - This is actually better for performance but more verbose
5. **When in doubt, check the std lib source** - It's the only truth in Zig's rapid evolution

---

## 10. Why These Changes?

Understanding the rationale helps:

- **ArrayList changes**: Removing internal allocator makes the structure smaller and more cache-friendly
- **I/O redesign**: New system is more composable and has better async support
- **Explicit allocators**: Makes memory ownership clearer and prevents hidden allocations

---

## Conclusion

Zig 0.16 has significant breaking changes, but they're manageable once you know the patterns. The hardest part is that most documentation and AI assistants are trained on older versions. Use this guide as your map through the migration minefield.

Remember: **When an AI suggests `ArrayList.init(allocator)`, it's thinking of Zig 0.13**. Always verify against your actual Zig version!

---

*Last updated: September 2025*
*Tested with: Zig 0.16.0-dev.218+1872c85ac*
*Battle-tested on: zig-financial-engine, quantum-alpaca-zig*
