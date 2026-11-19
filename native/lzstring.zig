//! lz-string compatible compressToBase64 / decompressFromBase64.
//!
//! Output is byte-identical to the JavaScript `lz-string` package for ASCII
//! input. Every input byte is treated as one character with code 0..255, so
//! non-ASCII UTF-8 text round-trips through this module but does not match
//! what JavaScript produces for the same text (JavaScript compresses UTF-16
//! code units).
//!
//! No allocator is used. The dictionaries live in fixed static tables, which
//! makes both functions non-reentrant: do not call them from two threads at
//! once.
//!
//! Limits:
//!   - compressToBase64 returns null for input longer than `max_input_len`.
//!   - decompressFromBase64 returns null when the stream needs more than
//!     `max_codes` dictionary entries, which cannot happen for data produced
//!     by compressing at most `max_input_len` bytes.
//!   - `maxCompressedLen` gives an output buffer size that always suffices.

/// Longest input accepted by compressToBase64, in bytes.
pub const max_input_len: usize = 16 * 1024;

/// Dictionary capacity. Each input character adds at most two entries (the
/// character itself and one phrase), on top of the three reserved codes.
const max_codes: usize = 2 * max_input_len + 4;

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Upper bound on the base64 length produced for `input_len` bytes.
/// Worst case per character is a literal (up to 16 code bits + 8 data bits)
/// followed by a phrase code (up to 16 bits); six bits go into each output
/// character, plus the end marker, final flush and padding.
pub fn maxCompressedLen(input_len: usize) usize {
    return (input_len * 40 + 16) / 6 + 8;
}

// ---------------------------------------------------------------------------
// Compression
// ---------------------------------------------------------------------------

const hash_bits = 16;
const hash_size: usize = 1 << hash_bits;

// Open-addressing hash table mapping (phrase code, next byte) to the code of
// the extended phrase. A stored key of 0 marks an empty slot.
var hash_keys: [hash_size]u32 = undefined;
var hash_vals: [hash_size]u16 = undefined;

fn hashSlot(key: u32) usize {
    return @as(usize, (key *% 2654435761) >> (32 - hash_bits));
}

fn phraseLookup(prefix: u32, ch: u8) ?u32 {
    const key: u32 = ((prefix << 8) | ch) + 1;
    var slot = hashSlot(key);
    while (hash_keys[slot] != 0) {
        if (hash_keys[slot] == key) return hash_vals[slot];
        slot = (slot + 1) & (hash_size - 1);
    }
    return null;
}

fn phraseInsert(prefix: u32, ch: u8, code: u32) void {
    const key: u32 = ((prefix << 8) | ch) + 1;
    var slot = hashSlot(key);
    while (hash_keys[slot] != 0) slot = (slot + 1) & (hash_size - 1);
    hash_keys[slot] = key;
    hash_vals[slot] = @intCast(code);
}

/// Packs bits into base64 characters, six per character, first bit highest.
const BitWriter = struct {
    out: []u8,
    len: usize = 0,
    val: u8 = 0,
    pos: u8 = 0,
    overflow: bool = false,

    fn emit(self: *BitWriter) void {
        if (self.len < self.out.len) {
            self.out[self.len] = alphabet[self.val];
            self.len += 1;
        } else {
            self.overflow = true;
        }
        self.val = 0;
    }

    fn push(self: *BitWriter, bit: u32) void {
        self.val = (self.val << 1) | @as(u8, @intCast(bit & 1));
        if (self.pos == 5) {
            self.pos = 0;
            self.emit();
        } else {
            self.pos += 1;
        }
    }

    /// Writes the low `count` bits of `value`, least significant bit first.
    fn bits(self: *BitWriter, value: u32, count: u32) void {
        var v = value;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            self.push(v & 1);
            v >>= 1;
        }
    }

    fn raw(self: *BitWriter, ch: u8) void {
        if (self.len < self.out.len) {
            self.out[self.len] = ch;
            self.len += 1;
        } else {
            self.overflow = true;
        }
    }
};

const Compressor = struct {
    bw: BitWriter,
    // Code assigned to each single byte, 0 while the byte is still unseen.
    char_code: [256]u32 = @splat(0),
    // True while a byte has a code but has not yet been written as a literal.
    pending_literal: [256]bool = @splat(false),
    dict_size: u32 = 3,
    num_bits: u32 = 2,
    enlarge_in: u32 = 2,

    fn countDown(self: *Compressor) void {
        self.enlarge_in -= 1;
        if (self.enlarge_in == 0) {
            self.enlarge_in = @as(u32, 1) << @intCast(self.num_bits);
            self.num_bits += 1;
        }
    }

    /// Writes the current phrase. A single byte seen for the first time goes
    /// out as code 0 followed by its eight bits; anything else goes out as
    /// its dictionary code.
    fn writePhrase(self: *Compressor, code: u32, len: usize, first: u8) void {
        if (len == 1 and self.pending_literal[first]) {
            self.bw.bits(0, self.num_bits);
            self.bw.bits(first, 8);
            self.countDown();
            self.pending_literal[first] = false;
        } else {
            self.bw.bits(code, self.num_bits);
        }
        self.countDown();
    }
};

/// Compresses `input` and writes standard padded base64 into `out`.
/// Returns the written slice, or null when `out` is too small or the input
/// exceeds `max_input_len`.
pub fn compressToBase64(input: []const u8, out: []u8) ?[]const u8 {
    if (input.len > max_input_len) return null;

    var i: usize = 0;
    while (i < hash_size) : (i += 1) hash_keys[i] = 0;

    var c = Compressor{ .bw = .{ .out = out } };

    // Current phrase: its dictionary code, length and first byte.
    var w_code: u32 = 0;
    var w_len: usize = 0;
    var w_first: u8 = 0;

    for (input) |ch| {
        if (c.char_code[ch] == 0) {
            c.char_code[ch] = c.dict_size;
            c.dict_size += 1;
            c.pending_literal[ch] = true;
        }

        if (w_len == 0) {
            w_code = c.char_code[ch];
            w_len = 1;
            w_first = ch;
            continue;
        }

        if (phraseLookup(w_code, ch)) |code| {
            w_code = code;
            w_len += 1;
            continue;
        }

        c.writePhrase(w_code, w_len, w_first);
        phraseInsert(w_code, ch, c.dict_size);
        c.dict_size += 1;
        w_code = c.char_code[ch];
        w_len = 1;
        w_first = ch;
    }

    if (w_len != 0) c.writePhrase(w_code, w_len, w_first);

    // End-of-stream marker, then fill the last character with zero bits.
    // The fill always produces one character, even on a character boundary.
    c.bw.bits(2, c.num_bits);
    while (true) {
        const last = c.bw.pos == 5;
        c.bw.push(0);
        if (last) break;
    }

    while (c.bw.len % 4 != 0 and !c.bw.overflow) c.bw.raw('=');

    if (c.bw.overflow) return null;
    return out[0..c.bw.len];
}

// ---------------------------------------------------------------------------
// Decompression
// ---------------------------------------------------------------------------

const no_prefix: u16 = 0xFFFF;

// Dictionary entry `n` is the text of entry dec_prefix[n] followed by the
// byte dec_char[n]; a literal has no prefix. dec_first and dec_len cache the
// first byte and total length of each entry.
var dec_prefix: [max_codes]u16 = undefined;
var dec_char: [max_codes]u8 = undefined;
var dec_first: [max_codes]u8 = undefined;
var dec_len: [max_codes]u32 = undefined;

fn base64Value(ch: u8) ?u8 {
    return switch (ch) {
        'A'...'Z' => ch - 'A',
        'a'...'z' => ch - 'a' + 26,
        '0'...'9' => ch - '0' + 52,
        '+' => 62,
        '/' => 63,
        // Padding carries no data bits.
        '=' => 0,
        else => null,
    };
}

/// Reads bits from base64 characters, highest of the six bits first.
/// Reading past the end yields zero bits, as the JavaScript library does.
const BitReader = struct {
    in: []const u8,
    index: usize = 0,
    val: u8 = 0,
    mask: u8 = 32,
    bad: bool = false,

    fn fetch(self: *BitReader) void {
        self.val = 0;
        if (self.index < self.in.len) {
            if (base64Value(self.in[self.index])) |v| {
                self.val = v;
            } else {
                self.bad = true;
            }
        }
        self.index += 1;
    }

    /// Reads `count` bits into a value, least significant bit first.
    fn bits(self: *BitReader, count: u32) u32 {
        var result: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.val & self.mask != 0) result |= @as(u32, 1) << @intCast(i);
            self.mask >>= 1;
            if (self.mask == 0) {
                self.mask = 32;
                self.fetch();
            }
        }
        return result;
    }
};

/// Copies the text of dictionary entry `code` to out[pos..] and returns the
/// position after it, or null when it does not fit.
fn writeEntry(code: usize, out: []u8, pos: usize) ?usize {
    const len: usize = dec_len[code];
    if (len > out.len - pos) return null;
    var i = pos + len;
    var cur = code;
    while (true) {
        i -= 1;
        out[i] = dec_char[cur];
        if (dec_prefix[cur] == no_prefix) break;
        cur = dec_prefix[cur];
    }
    return pos + len;
}

/// Decompresses base64 text produced by compressToBase64 (or by the
/// JavaScript library) into `out`. Returns the written slice, which is empty
/// for the compressed form of the empty string. Returns null for empty or
/// malformed input, for characters above code 255, when the dictionary
/// capacity is exceeded, or when `out` is too small.
pub fn decompressFromBase64(input: []const u8, out: []u8) ?[]const u8 {
    if (input.len == 0) return null;

    var r = BitReader{ .in = input };
    r.fetch();

    var dict_size: usize = 4;
    var enlarge_in: u32 = 4;
    var num_bits: u32 = 3;

    // The stream opens with a literal, or with the end marker when the
    // original text was empty.
    const first: u32 = switch (r.bits(2)) {
        0 => r.bits(8),
        1 => r.bits(16),
        2 => return if (r.bad) null else out[0..0],
        else => return null,
    };
    if (r.bad or first > 255) return null;

    dec_prefix[3] = no_prefix;
    dec_char[3] = @intCast(first);
    dec_first[3] = @intCast(first);
    dec_len[3] = 1;

    // Entry emitted most recently.
    var w: usize = 3;
    var pos: usize = writeEntry(3, out, 0) orelse return null;

    while (true) {
        if (r.bad or r.index > input.len) return null;
        if (num_bits > 24) return null;

        var code: usize = r.bits(num_bits);
        switch (code) {
            0, 1 => {
                const lit = r.bits(if (code == 0) 8 else 16);
                if (lit > 255 or dict_size >= max_codes) return null;
                dec_prefix[dict_size] = no_prefix;
                dec_char[dict_size] = @intCast(lit);
                dec_first[dict_size] = @intCast(lit);
                dec_len[dict_size] = 1;
                code = dict_size;
                dict_size += 1;
                enlarge_in -= 1;
            },
            2 => return if (r.bad) null else out[0..pos],
            else => {},
        }

        if (enlarge_in == 0) {
            enlarge_in = @as(u32, 1) << @intCast(num_bits);
            num_bits += 1;
        }

        if (code > dict_size or dict_size >= max_codes) return null;

        // The new entry is the previous text plus the first byte of the text
        // being emitted now. A code equal to dict_size refers to this very
        // entry, whose first byte is then the first byte of the previous one.
        const next_first = if (code == dict_size) dec_first[w] else dec_first[code];
        dec_prefix[dict_size] = @intCast(w);
        dec_char[dict_size] = next_first;
        dec_first[dict_size] = dec_first[w];
        dec_len[dict_size] = dec_len[w] + 1;

        pos = writeEntry(code, out, pos) orelse return null;

        dict_size += 1;
        enlarge_in -= 1;
        w = code;

        if (enlarge_in == 0) {
            enlarge_in = @as(u32, 1) << @intCast(num_bits);
            num_bits += 1;
        }
    }
}
