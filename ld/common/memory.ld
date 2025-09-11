/** FIXME:
 * Disable execute from RAM?
 *   May not be possible on some hw
 *   Safety concerns
 */
MEMORY
{
	flash (r!wx) : ORIGIN = FLASH_START, LENGTH = FLASH_SIZE
	ram (rwx)    : ORIGIN = RAM_START,   LENGTH = RAM_SIZE
}
