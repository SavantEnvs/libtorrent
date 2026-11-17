// Disable LeakSanitizer at build time for every fuzz + standalone binary (leaks are not the bug
// class this integration fuzzes for). ASan's memory-error checks and UBSan stay fully active.
extern "C" int __lsan_is_turned_off() { return 1; }
