/*
** music_coremidi_mididevice.mm
** Provides access to CoreMIDI on macOS for hardware MIDI playback
**
**---------------------------------------------------------------------------
** Copyright 2025 GZDoom Maintainers and Contributors
** All rights reserved.
**
** Redistribution and use in source and binary forms, with or without
** modification, are permitted provided that the following conditions
** are met:
**
** 1. Redistributions of source code must retain the above copyright
**    notice, this list of conditions and the following disclaimer.
** 2. Redistributions in binary form must reproduce the above copyright
**    notice, this list of conditions and the following disclaimer in the
**    documentation and/or other materials provided with the distribution.
** 3. The name of the author may not be used to endorse or promote products
**    derived from this software without specific prior written permission.
**
** THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR
** IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
** OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
** IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT,
** INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
** NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
** DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
** THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
** (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
** THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
**---------------------------------------------------------------------------
**
*/

#include <CoreMIDI/CoreMIDI.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <CoreAudio/HostTime.h>
#include <pthread.h>
#include <unistd.h> // For usleep

#include <queue>
#include <mutex>
#include <condition_variable>
#include <thread>

#include "mididevice.h"
#include "zmusic/mididefs.h"

//==========================================================================
//
// CoreMIDIDevice - CoreMIDI implementation for macOS
//
// Based on WinMIDIDevice (Windows) and AlsaMIDIDevice (Linux) patterns
//
//==========================================================================

class CoreMIDIDevice : public MIDIDevice
{
public:
	CoreMIDIDevice(int deviceID);
	~CoreMIDIDevice();

	int Open() override;
	void Close() override;
	bool IsOpen() const override;
	int GetTechnology() const override;
	int SetTempo(int tempo) override;
	int SetTimeDiv(int timediv) override;
	int StreamOut(MidiHeader *data) override;
	int StreamOutSync(MidiHeader *data) override;
	int Resume() override;
	void Stop() override;
	bool Pause(bool paused) override;
	bool FakeVolume() override;
	void InitPlayback() override;

protected:
	void CalcTickRate();
	int PlayTick();

	// CoreMIDI handles
	MIDIClientRef midiClient;
	MIDIPortRef midiOutPort;
	MIDIEndpointRef midiDestination;
	int deviceID;

	// Threading
	std::thread PlayerThread;
	bool ExitRequested;
	bool Paused;
	std::condition_variable EventCV; // Still needed for pause/resume
	std::mutex EventMutex; // Still needed for pause/resume

	bool isOpen;

	// Timing
	int Tempo;
	int Division;
	MIDITimeStamp CurrentEventHostTime; // This will track the host time of the current event being processed.
	double HostUnitsPerTick; // Conversion factor: Host Time Units per MIDI Tick.
	MidiHeader *Events; // Linked list of MIDI headers
	uint32_t Position; // Current position in the MidiHeader buffer

	// Thread functions
	static void PlayerThreadProc(CoreMIDIDevice* device);
	void PlayerLoop();

	void SendMIDIData(const uint8_t* data, size_t length, uint64_t timestamp);
};

//==========================================================================
//
// CoreMIDIDevice :: Constructor
//
//==========================================================================

CoreMIDIDevice::CoreMIDIDevice(int deviceID)
	: deviceID(deviceID)
	, midiClient(0)
	, midiOutPort(0)
	, midiDestination(0)
	, ExitRequested(false)
	, Paused(false)
	, isOpen(false)
	, Tempo(500000)      // Default: 120 BPM (500,000 µs per quarter note)
	, Division(96)       // Default PPQN
	, CurrentEventHostTime(0)
	, Events(nullptr)
	, Position(0)
{
}

//==========================================================================
//
// CoreMIDIDevice :: Destructor
//
//==========================================================================

CoreMIDIDevice::~CoreMIDIDevice()
{
	Close();
}

//==========================================================================
//
// CoreMIDIDevice :: Open
//
// Opens the MIDI device and connects to the specified endpoint
//
//==========================================================================

int CoreMIDIDevice::Open()
{
	if (isOpen)
		return 0;

	OSStatus status;

	// Create MIDI client
	status = MIDIClientCreate(CFSTR("GZDoom"), nullptr, nullptr, &midiClient);
	if (status != noErr)
	{
		fprintf(stderr, "CoreMIDI: Failed to create MIDI client (error %d)\n", (int)status);
		return -1;
	}

	// Create output port
	status = MIDIOutputPortCreate(midiClient, CFSTR("GZDoom Output"), &midiOutPort);
	if (status != noErr)
	{
		fprintf(stderr, "CoreMIDI: Failed to create output port (error %d)\n", (int)status);
		MIDIClientDispose(midiClient);
		midiClient = 0;
		return -1;
	}

	// Get destination endpoint by device ID
	ItemCount destCount = MIDIGetNumberOfDestinations();
	if (deviceID < 0 || deviceID >= (int)destCount)
	{
		fprintf(stderr, "CoreMIDI: Invalid device ID %d (available: %d)\n", deviceID, (int)destCount);
		MIDIPortDispose(midiOutPort);
		MIDIClientDispose(midiClient);
		midiOutPort = 0;
		midiClient = 0;
		return -1;
	}

	midiDestination = MIDIGetDestination(deviceID);
	if (midiDestination == 0)
	{
		fprintf(stderr, "CoreMIDI: Failed to get destination for device %d\n", deviceID);
		MIDIPortDispose(midiOutPort);
		MIDIClientDispose(midiClient);
		midiOutPort = 0;
		midiClient = 0;
		return -1;
	}

	// Get device name for logging
	CFStringRef deviceName = nullptr;
	MIDIObjectGetStringProperty(midiDestination, kMIDIPropertyName, &deviceName);
	if (deviceName != nullptr)
	{
		char nameBuf[256];
		CFStringGetCString(deviceName, nameBuf, sizeof(nameBuf), kCFStringEncodingUTF8);
		printf("CoreMIDI: Opened device %d: %s\n", deviceID, nameBuf);
		CFRelease(deviceName);
	}

	isOpen = true;
	return 0;
}

//==========================================================================
//
// CoreMIDIDevice :: Close
//
//==========================================================================

void CoreMIDIDevice::Close()
{
	if (!isOpen)
		return;

	// Stop player thread
	Stop();

	// Wait for thread to exit
	if (PlayerThread.joinable())
	{
		ExitRequested = true;
		EventCV.notify_all();
		PlayerThread.join();
	}

	// Send All Notes Off and Reset All Controllers
	for (int channel = 0; channel < 16; ++channel)
	{
		uint8_t msg1[3] = { (uint8_t)(0xB0 | channel), 123, 0 };
		SendMIDIData(msg1, 3, 0);  // All Notes Off
		uint8_t msg2[3] = { (uint8_t)(0xB0 | channel), 121, 0 };
		SendMIDIData(msg2, 3, 0);  // Reset All Controllers
	}

	// Dispose CoreMIDI objects
	if (midiOutPort != 0)
	{
		MIDIPortDispose(midiOutPort);
		midiOutPort = 0;
	}

	if (midiClient != 0)
	{
		MIDIClientDispose(midiClient);
		midiClient = 0;
	}

	midiDestination = 0;
	isOpen = false;

	printf("CoreMIDI: Device closed\n");
}

//==========================================================================
//
// CoreMIDIDevice :: IsOpen
//
//==========================================================================

bool CoreMIDIDevice::IsOpen() const
{
	return isOpen;
}

//==========================================================================
//
// CoreMIDIDevice :: GetTechnology
//
//==========================================================================

int CoreMIDIDevice::GetTechnology() const
{
	// Query if device is offline/virtual
	if (midiDestination != 0)
	{
		SInt32 offline = 0;
		MIDIObjectGetIntegerProperty(midiDestination, kMIDIPropertyOffline, &offline);
		return offline ? MIDIDEV_SWSYNTH : MIDIDEV_MIDIPORT;
	}
	return MIDIDEV_MIDIPORT;
}

//==========================================================================
//
// CoreMIDIDevice :: CalcTickRate
//
//==========================================================================

void CoreMIDIDevice::CalcTickRate()
{
	// Tempo is in microseconds per quarter note. Division is PPQN.
	// Host time units per second = AudioGetHostClockFrequency()
	// Microseconds per second = 1,000,000
	// Microseconds per tick = Tempo / Division
	// Host time units per tick = (Microseconds per tick) * (Host time units per second / Microseconds per second)
	Float64 hostClockFrequency = AudioGetHostClockFrequency();
	HostUnitsPerTick = ((double)Tempo / (double)Division) * (hostClockFrequency / 1000000.0);
}

//==========================================================================
//
// CoreMIDIDevice :: SetTempo
//
// Sets the playback tempo (microseconds per quarter note)
//
//==========================================================================

int CoreMIDIDevice::SetTempo(int tempo)
{
	Tempo = tempo;
	CalcTickRate();
	return 0;
}

//==========================================================================
//
// CoreMIDIDevice :: SetTimeDiv
//
// Sets the time division (PPQN - pulses per quarter note)
//
//==========================================================================

int CoreMIDIDevice::SetTimeDiv(int timediv)
{
	Division = timediv > 0 ? timediv : 96;
	CalcTickRate();
	return 0;
}

//==========================================================================
//
// CoreMIDIDevice :: StreamOut
//
// Queue MIDI data for asynchronous playback
//
//==========================================================================

int CoreMIDIDevice::StreamOut(MidiHeader *data)
{
	if (!isOpen)
		return -1;

	data->lpNext = nullptr;
	if (Events == nullptr)
	{
		Events = data;
		Position = 0;
	}
	else
	{
		MidiHeader **p;
		for (p = &Events; *p != nullptr; p = &(*p)->lpNext)
		{
		}
		*p = data;
	}
	return 0;
}

//==========================================================================
//
// CoreMIDIDevice :: StreamOutSync
//
// Queue MIDI data for synchronous playback
//
//==========================================================================

int CoreMIDIDevice::StreamOutSync(MidiHeader *data)
{
	return StreamOut(data);
}

//==========================================================================
//
// CoreMIDIDevice :: Resume
//
// Start or resume playback
//
//==========================================================================

int CoreMIDIDevice::Resume()
{
	if (!isOpen)
		return -1;

	if (!PlayerThread.joinable())
	{
		ExitRequested = false;
		Paused = false;
		PlayerThread = std::thread(PlayerThreadProc, this);
	}
	else
	{
		Paused = false;
		EventCV.notify_all();
	}

	return 0;
}

//==========================================================================
//
// CoreMIDIDevice :: Stop
//
// Stop playback
//
//==========================================================================

void CoreMIDIDevice::Stop()
{
	if (!isOpen)
		return;

	if (PlayerThread.joinable())
	{
		ExitRequested = true;
		EventCV.notify_all();
		PlayerThread.join();
	}

	// Clear event queue
	Events = nullptr;
}

//==========================================================================
//
// CoreMIDIDevice :: Pause
//
// Pause/resume playback
//
//==========================================================================

bool CoreMIDIDevice::Pause(bool paused)
{
	Paused = paused;

	if (!paused)
	{
		EventCV.notify_all();
	}

	return true;
}

//==========================================================================
//
// CoreMIDIDevice :: FakeVolume
//
// CoreMIDI doesn't support volume control directly
//
//==========================================================================

bool CoreMIDIDevice::FakeVolume()
{
	return false;  // No volume support
}

//==========================================================================
//
// CoreMIDIDevice :: InitPlayback
//
// Initialize playback state
//
//==========================================================================

void CoreMIDIDevice::InitPlayback()
{
	CurrentEventHostTime = AudioGetCurrentHostTime(); // Initialize with current host time
	Position = 0;
	Events = nullptr;
	CalcTickRate();
}

//==========================================================================
//
// CoreMIDIDevice :: PlayTick
//
// Plays all events up to the current tick.
//
//==========================================================================

int CoreMIDIDevice::PlayTick()
{
	if (Events == nullptr && Callback)
	{
		// All events in the current MidiHeader processed, request next buffer
		Callback(CallbackData);
	}

	if (Events == nullptr)
	{
		// No events available to process.
		return 0;
	}

	// Read the delta time (first 4 bytes of the event)
	uint32_t *event_ptr = (uint32_t *)(Events->lpData + Position);
	uint32_t midi_delta_ticks = event_ptr[0]; // Assuming delta time is the first uint32_t

	// Advance CurrentEventHostTime based on delta ticks.
	// This timestamp will be used for the current event.
	CurrentEventHostTime += (MIDITimeStamp)(midi_delta_ticks * HostUnitsPerTick);

	uint32_t len; // Length of the current MIDI event in bytes
	uint32_t midi_event_type_param = event_ptr[2]; // This is the actual MIDI event or meta-event info

	if (midi_event_type_param < 0x80000000) // Short message (midi_event_type_param is the combined status/data bytes)
	{
		len = 12; // 4 bytes delta time, 4 bytes reserved, 4 bytes MIDI message (up to 3 bytes + padding)
	}
	else // Long message or meta-event (midi_event_type_param holds type and parameter length)
	{
		len = 12 + ((MEVENT_EVENTPARM(midi_event_type_param) + 3) & ~3);
	}

	if (MEVENT_EVENTTYPE(midi_event_type_param) == MEVENT_TEMPO)
	{
		// Tempo change event, update our internal calculation for future events
		SetTempo(MEVENT_EVENTPARM(midi_event_type_param));
	}
	else if (MEVENT_EVENTTYPE(midi_event_type_param) == MEVENT_LONGMSG)
	{
		// Long MIDI message (SysEx, etc.), data starts after event_ptr[3]
		SendMIDIData((uint8_t *)&event_ptr[3], MEVENT_EVENTPARM(midi_event_type_param), CurrentEventHostTime);
	}
	else if (MEVENT_EVENTTYPE(midi_event_type_param) == 0) // Short MIDI message (note on/off, control change, etc.)
	{
		// midi_event_type_param contains the 1, 2, or 3 byte MIDI message
		uint8_t msg[3] = { (uint8_t)(midi_event_type_param & 0xff),
						   (uint8_t)((midi_event_type_param >> 8) & 0xff),
						   (uint8_t)((midi_event_type_param >> 16) & 0xff) };
		int msgLen = 0;
		if (msg[0] >= 0xF0) // System messages
		{
			if (msg[0] == 0xF0 || msg[0] == 0xF7) msgLen = 1; // Start/Stop/Continue/Timing/Active Sensing/Reset (1 byte)
			else if (msg[0] == 0xF1 || msg[0] == 0xF3) msgLen = 2; // Time Code Quarter Frame, Song Select (2 bytes)
			else if (msg[0] == 0xF2) msgLen = 3; // Song Position Pointer (3 bytes)
			else msgLen = 1; // Default to 1 for other unknown system messages
		}
		else if (msg[0] >= 0xC0 && msg[0] < 0xE0) // Program Change or Channel Aftertouch (2 bytes)
		{
			msgLen = 2;
		}
		else // Note On/Off, Poly Aftertouch, Control Change, Pitch Bend (3 bytes)
		{
			msgLen = 3;
		}
		SendMIDIData(msg, msgLen, CurrentEventHostTime);
	}
	// Other MEVENT_EVENTTYPE values (e.g., MEVENT_NOTEON, MEVENT_NOTEOFF etc. from WinMIDI)
	// are not directly used here; the raw MIDI message is parsed from event_ptr[2]

	Position += len;
	if (Position >= Events->dwBytesRecorded)
	{
		// Current MidiHeader buffer exhausted, move to the next one
		Events = Events->lpNext;
		Position = 0;
	}
	
	// Indicate that an event was processed and potentially more are available in the current tick.
	// The PlayerLoop will decide when to call PlayTick again.
	return 1;
}

//==========================================================================
//
// CoreMIDIDevice :: PlayerThreadProc
//
// Static thread entry point
//
//==========================================================================

void CoreMIDIDevice::PlayerThreadProc(CoreMIDIDevice* device)
{
	pthread_setname_np("CoreMIDI Player");
	device->PlayerLoop();
}

//==========================================================================
//
// CoreMIDIDevice :: PlayerLoop
//
// Main player thread loop - processes MIDI events from queue
//
//==========================================================================

void CoreMIDIDevice::PlayerLoop()
{
	while (!ExitRequested)
	{
		// Process all available events and schedule them with CoreMIDI
		while (Events != nullptr && !Paused && !ExitRequested)
		{
			// PlayTick returns 1 if an event was processed.
			// It will continue to be called until Events becomes nullptr.
			PlayTick();
		}

		// After processing all currently available events, or if paused/exit requested,
		// wait for new data, unpause, or exit signal.
		std::unique_lock<std::mutex> lock(EventMutex);
		EventCV.wait(lock, [&]{
			return Paused || ExitRequested || Events != nullptr; // Wake up if paused, exit requested, or new events available
		});

		// If paused, just wait until unpaused or exit requested
		while (Paused && !ExitRequested)
		{
			EventCV.wait(lock);
		}
	}
}

//==========================================================================
//
// CoreMIDIDevice :: SendMIDIData
//
// Send raw MIDI data to the CoreMIDI output port
//
//==========================================================================

void CoreMIDIDevice::SendMIDIData(const uint8_t* data, size_t length, uint64_t timestamp)
{
	if (!isOpen || midiOutPort == 0 || midiDestination == 0)
		return;

	// The required size for the MIDIPacketList is the size of the list itself
	// plus the size of the packet header and the actual MIDI data.
	size_t requiredSize = offsetof(MIDIPacketList, packet) + offsetof(MIDIPacket, data) + length;

	// Use a stack buffer for small messages to avoid heap allocation (fast path).
	Byte small_buffer[256];

	// Choose the buffer to use.
	Byte* buffer;
	std::vector<Byte> large_buffer; // Will be used only if needed.

	if (requiredSize > sizeof(small_buffer))
	{
		try
		{
			large_buffer.resize(requiredSize);
			buffer = large_buffer.data();
		}
		catch (const std::bad_alloc&)
		{
			fprintf(stderr, "CoreMIDI: Failed to allocate memory for large MIDI message.\n");
			return;
		}
	}
	else
	{
		buffer = small_buffer;
	}

	MIDIPacketList* packetList = (MIDIPacketList*)buffer;
	MIDIPacket* packet = MIDIPacketListInit(packetList);

	// Add the MIDI data to the packet list. The size passed to MIDIPacketListAdd
	// is the total size of the buffer we have available.
	packet = MIDIPacketListAdd(packetList, (buffer == small_buffer) ? sizeof(small_buffer) : requiredSize, packet,
								timestamp, length, data);

	if (packet != nullptr)
	{
		OSStatus status = MIDISend(midiOutPort, midiDestination, packetList);
		if (status != noErr)
		{
			fprintf(stderr, "CoreMIDI: MIDISend failed (error %d)\n", (int)status);
		}
	}
	else
	{
		// This should ideally not happen with dynamic allocation, but we keep the check for safety.
		fprintf(stderr, "CoreMIDI: MIDIPacketListAdd failed unexpectedly.\n");
	}
}



//==========================================================================
//
// CreateCoreMIDIDevice
//
// Factory function to create a CoreMIDI device instance
//
//==========================================================================

MIDIDevice* CreateCoreMIDIDevice(int mididevice)
{
	return new CoreMIDIDevice(mididevice);
}