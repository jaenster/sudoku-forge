// The exported interface of core/solver.zig, linked in as an object file.

pub const NONE: u8 = 255;
pub const MAX_THERMO = 16;

pub const Status = struct {
    pub const none: u32 = 0;
    pub const unique: u32 = 1;
    pub const multiple: u32 = 2;
    pub const at_least_one: u32 = 3;
    pub const unknown: u32 = 4;
};

pub extern fn setRules(mask: u32) void;
pub extern fn setDeepLogic(on: u32) void;
pub extern fn probe(cell: u32, digit: u32, cap: u32, digits_shown: u32) u32;
pub extern fn analyze(cap: u32, digits_shown: u32) u32;
pub extern fn generate(seed: u32, sym: u32, max_size: u32, merges: u32, logic_only: u32, thermos: u32, removals: u32, fill: u32, use_user: u32, digits_shown: u32) u32;
pub extern fn guesses() u32;
pub extern fn ruleSteps() u32;

/// Uses per solving step in the last analysis, easiest step first.
pub const TECHNIQUES = 9;
pub extern fn techniquePtr() [*]u32;
/// 1 when the 81 digits satisfy every clue in the user buffers.
pub extern fn checkGrid(ptr: [*]const u8) u32;

pub extern fn userCagePtr() [*]u8;
pub extern fn userSumPtr() [*]u16;
pub extern fn userThermoPtr() [*]u8;
pub extern fn userThermoLenPtr() [*]u8;
pub extern fn setUserThermoCount(n: u32) void;
pub extern fn userDigitPtr() [*]u8;
pub extern fn userHiddenPtr() [*]u8;
pub extern fn userMaskPtr() [*]u16;

pub const MAX_LINE = 24;
pub const Line = struct {
    pub const arrow: u8 = 1;
    pub const whisper: u8 = 2;
    pub const renban: u8 = 3;
    pub const palindrome: u8 = 4;
};
pub extern fn userLineCellPtr() [*]u8;
pub extern fn userLineLenPtr() [*]u8;
pub extern fn userLineKindPtr() [*]u8;
pub extern fn setUserLineCount(n: u32) void;
pub extern fn redundantLinePtr() [*]u8;

pub const MAX_LINK = 144;
pub const Link = struct {
    pub const less: u8 = 1;
    pub const sum: u8 = 2;
    pub const diff: u8 = 3;
    pub const ratio: u8 = 4;
};
pub extern fn userLinkPtr() [*]u8;
pub extern fn setUserLinkCount(n: u32) void;
pub extern fn redundantLinkPtr() [*]u8;

pub extern fn analysisCandPtr() [*]u16;
pub extern fn analysisSolutionPtr() [*]u8;
pub extern fn redundantCagePtr() [*]u8;
pub extern fn redundantThermoPtr() [*]u8;
pub extern fn redundantDigitPtr() [*]u8;

pub extern fn solutionPtr() [*]u8;
pub extern fn cagePtr() [*]u8;
