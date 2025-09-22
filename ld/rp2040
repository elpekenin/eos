INCLUDE ld/common/entry.ld;

RAM_START = 0x20000000;
RAM_SIZE  = 256k;

FLASH_START = 0x10000000;
FLASH_SIZE  = 2M; /* TODO: make configurable, 2M is bare minimum, but can go up to 16M */

KERNEL_STACK_SIZE = 30k; /* TODO: make configurable */ 

INCLUDE ld/common/memory.ld;

SECTIONS
{
  .boot2 : {
    __boot2_start__ = .;
    KEEP (*(.boot2))
    __boot2_end__ = .;
  } > flash

  ASSERT(__boot2_end__ - __boot2_start__ == 0x100, "boot2 must be 256 bytes")
}

INCLUDE ld/common/sections.ld;
