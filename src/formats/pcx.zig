// Adapted from https://github.com/MasterQ32/zig-gamedev-lib/blob/master/src/pcx.zig
// with permission from Felix Queißner
const Allocator = std.mem.Allocator;
const buffered_stream_source = @import("../buffered_stream_source.zig");
const color = @import("../color.zig");
const FormatInterface = @import("../FormatInterface.zig");
const Image = @import("../Image.zig");
const ImageError = Image.Error;
const ImageReadError = Image.ReadError;
const ImageWriteError = Image.WriteError;
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const std = @import("std");
const utils = @import("../utils.zig");
const simd = @import("../simd.zig");

pub const PCXHeader = extern struct {
    id: u8 = 0x0A,
    version: u8,
    compression: u8,
    bpp: u8,
    xmin: u16 align(1),
    ymin: u16 align(1),
    xmax: u16 align(1),
    ymax: u16 align(1),
    horizontal_dpi: u16 align(1),
    vertical_dpi: u16 align(1),
    builtin_palette: [48]u8,
    _reserved0: u8 = 0,
    planes: u8,
    stride: u16 align(1),
    palette_information: u16 align(1),
    screen_width: u16 align(1),
    screen_height: u16 align(1),

    // HACK: For some reason, padding as field does not report 128 bytes for the header.
    var padding: [54]u8 = undefined;

    comptime {
        std.debug.assert(@sizeOf(@This()) == 74);
    }
};

const RLEDecoder = struct {
    const Run = struct {
        value: u8,
        remaining: usize,
    };

    reader: buffered_stream_source.DefaultBufferedStreamSourceReader.Reader,
    current_run: ?Run,

    fn init(reader: buffered_stream_source.DefaultBufferedStreamSourceReader.Reader) RLEDecoder {
        return RLEDecoder{
            .reader = reader,
            .current_run = null,
        };
    }

    fn readByte(self: *RLEDecoder) ImageReadError!u8 {
        if (self.current_run) |*run| {
            var result = run.value;
            run.remaining -= 1;
            if (run.remaining == 0) {
                self.current_run = null;
            }
            return result;
        } else {
            while (true) {
                var byte = try self.reader.readByte();
                if (byte == 0xC0) // skip over "zero length runs"
                    continue;
                if ((byte & 0xC0) == 0xC0) {
                    const len = byte & 0x3F;
                    std.debug.assert(len > 0);
                    const result = try self.reader.readByte();
                    if (len > 1) {
                        // we only need to store a run in the decoder if it is longer than 1
                        self.current_run = .{
                            .value = result,
                            .remaining = len - 1,
                        };
                    }
                    return result;
                } else {
                    return byte;
                }
            }
        }
    }

    fn finish(decoder: RLEDecoder) ImageReadError!void {
        if (decoder.current_run != null) {
            return ImageReadError.InvalidData;
        }
    }
};

const RLEEncoder = struct {
    const LengthToCheck = 16;
    const VectorType = @Vector(LengthToCheck, u8);

    const RlePair = packed struct(u8) {
        length: u6 = 0,
        identifier: u2 = (1 << 2) - 1,
    };

    pub fn encode(source_data: []const u8, writer: anytype) !void {
        if (source_data.len == 0) {
            return;
        }

        var index: usize = 0;

        var total_similar_count: usize = 0;

        var current_byte: u8 = 0;

        while (index < source_data.len and (index + LengthToCheck) <= source_data.len) {
            // Read current byte
            current_byte = source_data[index];

            const current_byte_splatted: VectorType = @splat(current_byte);
            const compare_chunk = simd.load(source_data[index..], VectorType, 0);

            const compare_mask = (current_byte_splatted == compare_chunk);
            const inverted_mask = ~@as(u16, @bitCast(compare_mask));
            const current_similar_count = @ctz(inverted_mask);

            if (current_similar_count == LengthToCheck) {
                total_similar_count += current_similar_count;
                index += current_similar_count;
            } else {
                total_similar_count += current_similar_count;

                try flush(writer, current_byte, total_similar_count);

                total_similar_count = 0;

                index += current_similar_count;
            }
        }

        try flush(writer, current_byte, total_similar_count);

        // Process the rest sequentially
        total_similar_count = 0;
        if (index < source_data.len) {
            current_byte = source_data[index];

            while (index < source_data.len) {
                const read_byte = source_data[index];
                if (read_byte == current_byte) {
                    total_similar_count += 1;
                } else {
                    try flush(writer, current_byte, total_similar_count);

                    current_byte = read_byte;
                    total_similar_count = 1;
                }

                index += 1;
            }

            try flush(writer, current_byte, total_similar_count);
        }
    }

    fn flush(writer: anytype, value: u8, count: usize) !void {
        var current_count = count;
        while (current_count > 0) {
            const length_to_write = @min(current_count, (1 << 6) - 1);

            if (length_to_write >= 3) {
                try flushRlePair(writer, value, length_to_write);
            } else {
                try flushRawBytes(writer, value, length_to_write);
            }

            current_count -= length_to_write;
        }
    }

    inline fn flushRlePair(writer: anytype, value: u8, count: usize) !void {
        const rle_pair = RlePair{
            .length = @truncate(count),
        };
        try writer.writeByte(@bitCast(rle_pair));
        try writer.writeByte(value);
    }

    inline fn flushRawBytes(writer: anytype, value: u8, count: usize) !void {
        // Must flush byte greater than 192 (0xC0) as a RLE pair
        if ((value & 0xC0) == 0xC0) {
            for (0..count) |_| {
                try flushRlePair(writer, value, 1);
            }
        } else {
            for (0..count) |_| {
                try writer.writeByte(value);
            }
        }
    }
};

test "PCX RLE encoder" {
    const uncompressed_data = [_]u8{ 1, 1, 1, 1, 1, 1, 1, 1, 1, 64, 64, 2, 2, 2, 2, 2, 215, 215, 215, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 200, 200, 200, 200, 210, 210 };
    const compressed_data = [_]u8{ 0xC9, 0x01, 0x40, 0x40, 0xC5, 0x02, 0xC3, 0xD7, 0xCA, 0x03, 0xC4, 0xC8, 0xC1, 0xD2, 0xC1, 0xD2 };

    var result_list = std.ArrayList(u8).init(std.testing.allocator);
    defer result_list.deinit();

    var writer = result_list.writer();

    try RLEEncoder.encode(uncompressed_data[0..], writer);

    try std.testing.expectEqualSlices(u8, compressed_data[0..], result_list.items);
}

test "PCX RLE encoder should encore more than 63 bytes similar" {
    const first_uncompressed_part = [_]u8{0x45} ** 65;
    const second_uncompresse_part = [_]u8{ 0x1, 0x1, 0x1, 0x1 };
    const uncompressed_data = first_uncompressed_part ++ second_uncompresse_part;

    const compressed_data = [_]u8{ 0xFF, 0x45, 0x45, 0x45, 0xC4, 0x1 };

    var result_list = std.ArrayList(u8).init(std.testing.allocator);
    defer result_list.deinit();

    var writer = result_list.writer();

    try RLEEncoder.encode(uncompressed_data[0..], writer);

    try std.testing.expectEqualSlices(u8, compressed_data[0..], result_list.items);
}

pub const PCX = struct {
    header: PCXHeader = undefined,
    width: usize = 0,
    height: usize = 0,

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .format = format,
            .formatDetect = formatDetect,
            .readImage = readImage,
            .writeImage = writeImage,
        };
    }

    pub fn format() Image.Format {
        return Image.Format.pcx;
    }

    pub fn formatDetect(stream: *Image.Stream) ImageReadError!bool {
        var magic_number_bufffer: [2]u8 = undefined;
        _ = try stream.read(magic_number_bufffer[0..]);

        if (magic_number_bufffer[0] != 0x0A) {
            return false;
        }

        if (magic_number_bufffer[1] > 0x05) {
            return false;
        }

        return true;
    }

    pub fn readImage(allocator: Allocator, stream: *Image.Stream) ImageReadError!Image {
        var result = Image.init(allocator);
        errdefer result.deinit();
        var pcx = PCX{};

        const pixels = try pcx.read(allocator, stream);

        result.width = pcx.width;
        result.height = pcx.height;
        result.pixels = pixels;

        return result;
    }

    pub fn writeImage(allocator: Allocator, write_stream: *Image.Stream, image: Image, encoder_options: Image.EncoderOptions) ImageWriteError!void {
        _ = allocator;
        _ = write_stream;
        _ = image;
        _ = encoder_options;
    }

    pub fn pixelFormat(self: PCX) ImageReadError!PixelFormat {
        if (self.header.planes == 1) {
            switch (self.header.bpp) {
                1 => return PixelFormat.indexed1,
                4 => return PixelFormat.indexed4,
                8 => return PixelFormat.indexed8,
                else => return ImageError.Unsupported,
            }
        } else if (self.header.planes == 3) {
            switch (self.header.bpp) {
                8 => return PixelFormat.rgb24,
                else => return ImageError.Unsupported,
            }
        } else {
            return ImageError.Unsupported;
        }
    }

    pub fn read(self: *PCX, allocator: Allocator, stream: *Image.Stream) ImageReadError!color.PixelStorage {
        var buffered_stream = buffered_stream_source.bufferedStreamSourceReader(stream);
        const reader = buffered_stream.reader();
        self.header = try utils.readStructLittle(reader, PCXHeader);
        _ = try buffered_stream.read(PCXHeader.padding[0..]);

        if (self.header.id != 0x0A) {
            return ImageReadError.InvalidData;
        }

        if (self.header.version > 0x05) {
            return ImageReadError.InvalidData;
        }

        if (self.header.planes > 3) {
            return ImageError.Unsupported;
        }

        const pixel_format = try self.pixelFormat();

        self.width = @as(usize, self.header.xmax - self.header.xmin + 1);
        self.height = @as(usize, self.header.ymax - self.header.ymin + 1);

        const has_dummy_byte = (@as(i16, @bitCast(self.header.stride)) - @as(isize, @bitCast(self.width))) == 1;
        const actual_width = if (has_dummy_byte) self.width + 1 else self.width;

        var pixels = try color.PixelStorage.init(allocator, pixel_format, self.width * self.height);
        errdefer pixels.deinit(allocator);

        var decoder = RLEDecoder.init(reader);

        const scanline_length = (self.header.stride * self.header.planes);

        var y: usize = 0;
        while (y < self.height) : (y += 1) {
            var offset: usize = 0;
            var x: usize = 0;

            const y_stride = y * self.width;

            // read all pixels from the current row
            while (offset < scanline_length and x < self.width) : (offset += 1) {
                const byte = try decoder.readByte();
                switch (pixels) {
                    .indexed1 => |storage| {
                        var i: usize = 0;
                        while (i < 8) : (i += 1) {
                            if (x < self.width) {
                                storage.indices[y_stride + x] = @intCast((byte >> (7 - @as(u3, @intCast(i)))) & 0x01);
                                x += 1;
                            }
                        }
                    },
                    .indexed4 => |storage| {
                        storage.indices[y_stride + x] = @truncate(byte >> 4);
                        x += 1;
                        if (x < self.width) {
                            storage.indices[y_stride + x] = @truncate(byte);
                            x += 1;
                        }
                    },
                    .indexed8 => |storage| {
                        storage.indices[y_stride + x] = byte;
                        x += 1;
                    },
                    .rgb24 => |storage| {
                        if (has_dummy_byte and byte == 0x00) {
                            continue;
                        }
                        const pixel_x = offset % (actual_width);
                        const current_color = offset / (actual_width);
                        switch (current_color) {
                            0 => {
                                storage[y_stride + pixel_x].r = byte;
                            },
                            1 => {
                                storage[y_stride + pixel_x].g = byte;
                            },
                            2 => {
                                storage[y_stride + pixel_x].b = byte;
                            },
                            else => {},
                        }

                        if (pixel_x > 0 and (pixel_x % self.header.planes) == 0) {
                            x += 1;
                        }
                    },
                    else => return ImageError.Unsupported,
                }
            }

            // discard the rest of the bytes in the current row
            while (offset < self.header.stride) : (offset += 1) {
                _ = try decoder.readByte();
            }
        }

        try decoder.finish();

        if (pixel_format == .indexed1 or pixel_format == .indexed4 or pixel_format == .indexed8) {
            var pal = switch (pixels) {
                .indexed1 => |*storage| storage.palette[0..],
                .indexed4 => |*storage| storage.palette[0..],
                .indexed8 => |*storage| storage.palette[0..],
                else => undefined,
            };

            var i: usize = 0;
            while (i < @min(pal.len, self.header.builtin_palette.len / 3)) : (i += 1) {
                pal[i].r = self.header.builtin_palette[3 * i + 0];
                pal[i].g = self.header.builtin_palette[3 * i + 1];
                pal[i].b = self.header.builtin_palette[3 * i + 2];
                pal[i].a = 1.0;
            }

            if (pixels == .indexed8) {
                const end_pos = try buffered_stream.getEndPos();
                try buffered_stream.seekTo(end_pos - 769);

                if ((try reader.readByte()) != 0x0C)
                    return ImageReadError.InvalidData;

                for (pal) |*c| {
                    c.r = try reader.readByte();
                    c.g = try reader.readByte();
                    c.b = try reader.readByte();
                    c.a = 1.0;
                }
            }
        }

        return pixels;
    }
};
