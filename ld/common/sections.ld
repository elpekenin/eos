SECTIONS
{
    /**
     * FLASH
     */
    . = ORIGIN(flash);

    PROVIDE(__kernel_flash_start = .);

    .text : {
        KEEP(*(.vector_table))
        *(.text*)
        *(.rodata*)
    } > flash

    . = ALIGN(4);

    /* remaining flash memory will store initialization values */
    PROVIDE(__kernel_data_source = .);

    /**
     * RAM
     */
    . = ORIGIN(ram);

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

    .data : AT(__kernel_data_source) {
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
    } > ram

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
