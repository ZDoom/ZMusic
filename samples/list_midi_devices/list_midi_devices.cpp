#include <stdio.h>
#include <zmusic.h>

int main()
{
	int count = 0;
	const MidiOutDevice *devices = ZMusic_GetMidiDevices(&count);
	
	for (int i = 0; i < count; ++i)
	{
		printf("[%i] %s\n", i, devices[i].Name);
	}
	
	return 0;
}
