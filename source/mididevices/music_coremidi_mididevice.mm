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
#include <pthread.h>

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
	// CoreMIDI handles
	MIDIClientRef midiClient;
	MIDIPortRef midiOutPort;
	MIDIEndpointRef midiDestination;
	int deviceID;

	// Threading
	std::thread PlayerThread;
	std::mutex EventMutex;
	std::condition_variable EventCV;
	bool ExitRequested;
	bool Paused;
	bool isOpen;

	// Timing
	int Tempo;
	int Division;
	uint64_t StartTime;

	// Event queue
	std::queue<MidiHeader*> EventQueue;

	// Thread functions
	static void PlayerThreadProc(CoreMIDIDevice* device);
	void PlayerLoop();
	void ProcessEvents(MidiHeader* header);
	void SendMIDIData(const uint8_t* data, size_t length, uint64_t timestamp);
	void SendShortMessage(uint8_t status, uint8_t data1, uint8_t data2);
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
	, StartTime(0)
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
		SendShortMessage(0xB0 | channel, 123, 0);  // All Notes Off
		SendShortMessage(0xB0 | channel, 121, 0);  // Reset All Controllers
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
// CoreMIDIDevice :: SetTempo
//
// Sets the playback tempo (microseconds per quarter note)
//
//==========================================================================

int CoreMIDIDevice::SetTempo(int tempo)
{
	Tempo = tempo;
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
	Division = timediv;
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

	std::lock_guard<std::mutex> lock(EventMutex);
	EventQueue.push(data);
	EventCV.notify_one();

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

	ExitRequested = true;
	EventCV.notify_all();

	if (PlayerThread.joinable())
	{
		PlayerThread.join();
	}

	// Clear event queue
	std::lock_guard<std::mutex> lock(EventMutex);
	while (!EventQueue.empty())
	{
		EventQueue.pop();
	}
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
	StartTime = mach_absolute_time();
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
		MidiHeader* header = nullptr;

		// Wait for events
		{
			std::unique_lock<std::mutex> lock(EventMutex);
			EventCV.wait(lock, [this] {
				return !EventQueue.empty() || ExitRequested;
			});

			if (ExitRequested)
				break;

			// Wait if paused
			EventCV.wait(lock, [this] {
				return !Paused || ExitRequested;
			});

			if (ExitRequested)
				break;

			if (!EventQueue.empty())
			{
				header = EventQueue.front();
				EventQueue.pop();
			}
		}

		if (header != nullptr)
		{
			ProcessEvents(header);

			// Notify completion via callback
			if (Callback)
			{
				Callback(CallbackData);
			}
		}
	}
}

//==========================================================================
//
// CoreMIDIDevice :: ProcessEvents
//
// Process MIDI events from a MidiHeader buffer
//
//==========================================================================

void CoreMIDIDevice::ProcessEvents(MidiHeader* header)
{
	const uint8_t* data = header->lpData;
	size_t length = header->dwBytesRecorded;
	uint64_t currentTime = mach_absolute_time();

	for (size_t i = 0; i < length; )
	{
		if (i + 4 > length)
			break;

		uint32_t event = *(uint32_t*)(data + i);
		uint8_t eventType = event & 0xFF;

		if (eventType == MEVENT_TEMPO)
		{
			// Tempo change event
			int tempo = (event >> 8) & 0xFFFFFF;
			SetTempo(tempo);
			i += 4;
		}
		else if (eventType == MEVENT_NOP)
		{
			// No operation
			i += 4;
		}
		else if (eventType == MEVENT_LONGMSG)
		{
			// Long message (SysEx)
			uint32_t msgLen = (event >> 8) & 0xFFFFFF;
			if (i + 4 + msgLen > length)
				break;

			SendMIDIData(data + i + 4, msgLen, currentTime);
			i += 4 + msgLen;
		}
		else if (eventType < 0x80)
		{
			// Short MIDI message (note on/off, control change, etc.)
			uint8_t status = (event >> 8) & 0xFF;
			uint8_t data1 = (event >> 16) & 0xFF;
			uint8_t data2 = (event >> 24) & 0xFF;

			// Determine message length based on status byte
			int msgLen = 3;
			if (status >= 0xC0 && status < 0xE0)
			{
				msgLen = 2;  // Program Change and Channel Pressure are 2 bytes
			}

			uint8_t msg[3] = { status, data1, data2 };
			SendMIDIData(msg, msgLen, currentTime);

			i += 4;
		}
		else
		{
			// Unknown event type - skip
			i += 4;
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

	// Create MIDI packet list (using stack buffer for small messages)
	Byte buffer[256];
	MIDIPacketList* packetList = (MIDIPacketList*)buffer;
	MIDIPacket* packet = MIDIPacketListInit(packetList);

	// Add packet with timestamp
	// Use current time for immediate playback (could be enhanced with timing)
	packet = MIDIPacketListAdd(packetList, sizeof(buffer), packet,
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
		fprintf(stderr, "CoreMIDI: MIDIPacketListAdd failed (buffer too small)\n");
	}
}

//==========================================================================
//
// CoreMIDIDevice :: SendShortMessage
//
// Convenience function for sending short MIDI messages
//
//==========================================================================

void CoreMIDIDevice::SendShortMessage(uint8_t status, uint8_t data1, uint8_t data2)
{
	uint8_t msg[3] = { status, data1, data2 };
	int msgLen = (status >= 0xC0 && status < 0xE0) ? 2 : 3;
	SendMIDIData(msg, msgLen, mach_absolute_time());
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
