INCLUDE ld/common/entry.ld;

FLASH_START = 0x08000000;
FLASH_SIZE  = 0x00010000;

RAM_START = 0x24000000;
RAM_SIZE  = 0x00071C00;

KERNEL_STACK_SIZE = 16k;

INCLUDE ld/common/memory.ld;
INCLUDE ld/common/sections.ld;
