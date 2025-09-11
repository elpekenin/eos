SECTIONS
{
	.text : {
		KEEP(*(.vector_table))
		*(.text*)
		*(.rodata*)
	} >flash

	/* Debug info (unwinding?) */
	/* .ARM.exidx */
	/DISCARD/ : {
		*(.ARM.exidx*)
		*(.ARM.extab*)
		*(.gnu.linkonce.armexidx.*)
	} >flash

	/* Preserved across reset */
	.noinit (NOLOAD) : {
		KEEP(*(.noinit*))
	} >ram

	.data : {
		PROVIDE(__data_start = .);
		*(.data.*)
		PROVIDE(__data_end = .);
	} >ram AT>flash

	.bss (NOLOAD) : {
		PROVIDE(__bss_start = .);
		*(.bss.*)
		PROVIDE(__bss_end = .);
	} >ram

	.stack (NOLOAD): {
		PROVIDE(__kernel_stack_start = .);
		. += KERNEL_STACK_SIZE;
		PROVIDE(__kernel_stack_end = .);
	} >ram

	.heap (NOLOAD) : {
		PROVIDE(__kernel_heap_start = .);
		. += ORIGIN(ram) + LENGTH(ram) - __kernel_heap_start;
		PROVIDE(__kernel_heap_end = .);
	} >ram

	PROVIDE(__data_source = LOADADDR(.data));
}
