/*
 * em95x-vfd-boot - put a short text on the EM95X front 7-segment display
 *
 * The OpenVFD misc device /dev/openvfd accepts exactly one
 * struct vfd_display_data (660 bytes) per write().  Any other length goes
 * down the "raw LED codes" path and fails with EIO.  The driver returns 0
 * on success (not the byte count), so never loop on a short write.
 *
 * The driver powers the display on when the device is opened and off when
 * the last user closes it, therefore --hold keeps the fd open so the text
 * stays visible (the clock service then takes over).
 *
 * Build:  gcc -O2 -o em95x-vfd-boot em95x-vfd-boot.c
 * Usage:  em95x-vfd-boot [text] [--hold]
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

struct vfd_display_data {
	unsigned short mode;
	unsigned char colon_on;
	unsigned char temperature;
	struct { unsigned char seconds, minutes, hours, day_of_week, day, month;
		 unsigned short year; } time_date;
	struct { unsigned char seconds, minutes, hours, _reserved; } time_secondary;
	struct { unsigned short channel, channel_count; } channel_data;
	char string_main[512];
	char string_secondary[128];
};

#define DISPLAY_MODE_TITLE 4

int main(int argc, char **argv)
{
	const char *text = "BOOT";
	int hold = 0, i;
	struct vfd_display_data d;
	ssize_t n;
	int fd;

	for (i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--hold"))
			hold = 1;
		else
			text = argv[i];
	}

	memset(&d, 0, sizeof(d));
	d.mode = DISPLAY_MODE_TITLE;
	snprintf(d.string_main, sizeof(d.string_main), "%s", text);

	fd = open("/dev/openvfd", O_WRONLY);
	if (fd < 0) {
		fprintf(stderr, "open /dev/openvfd: %s\n", strerror(errno));
		return 1;
	}

	/* the driver returns 0 on success here, the byte count is not reported */
	n = write(fd, &d, sizeof(d));
	if (n < 0) {
		fprintf(stderr, "write: %s\n", strerror(errno));
		close(fd);
		return 1;
	}

	if (hold)
		for (;;)
			pause();

	close(fd);
	return 0;
}
