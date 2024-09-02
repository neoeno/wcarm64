AS = as
ASFLAGS =
XCRUN = xcrun
LD = ld
LDFLAGS = -lSystem -syslibroot `$(XCRUN) -sdk macosx --show-sdk-path`

all: 	wcarm64

wcarm64: wcarm64.o
	$(LD) $(LDFLAGS) -o $@ $<

%.o: %.s
	$(AS) $(ASFLAGS) $< -o $@

clean:
	rm -f *.o wcarm64 a.out
