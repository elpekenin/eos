SECTIONS
{
    /**
     * FLASH
     */
    .text : {
        PROVIDE(__kernel_flash_start = .);

        /* vector table and whatnot */
        KEEP(*(.startup))

        *(.text*)
        *(.rodata*)
    } > flash

    /* if we dont discard these, they might mess up location of vector table */
    /DISCARD/ : {
        *(.ARM.exidx*)
        *(.ARM.extab*)
        *(.gnu.linkonce.armexidx.*)
    } > flash

    /**
     * RAM
     */
    .stack (NOLOAD) : {
        . = ALIGN(4k);
        PROVIDE(__kernel_stack_start = .);

        . += KERNEL_STACK_SIZE;

        . = ALIGN(4);
        PROVIDE(__kernel_stack_end = .);
    } > ram

    .bss (NOLOAD) : {
        . = ALIGN(4);
        PROVIDE(__kernel_bss_start = .);

        *(.bss.*)

        . = ALIGN(4);
        PROVIDE(__kernel_bss_end = .);
    } > ram

    .data : {
        . = ALIGN(4);
        PROVIDE(__kernel_data_start = .);

        . = ALIGN(4);
        *(.ramtext*)

        . = ALIGN(4);
        *(.data.*)

        . = ALIGN(4);
        *(.sdata.*)

        . = ALIGN(4);
        PROVIDE(__kernel_data_end = .);
    } > ram AT> flash

    PROVIDE(__kernel_data_source = LOADADDR(.data));

    /* Preserved across reset */
    .noinit (NOLOAD) : {
        KEEP(*(.noinit*))
    } > ram

    .heap (NOLOAD) : {
        . = ALIGN(4);
        PROVIDE(__kernel_heap_start = .);

        . += ORIGIN(ram) + LENGTH(ram) - __kernel_heap_start;

        . = ALIGN(4);
        PROVIDE(__kernel_heap_end = .);
    } > ram
}
