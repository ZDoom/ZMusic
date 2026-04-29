/*
** Provides an ALSA implementation of a MIDI output device.
**
**---------------------------------------------------------------------------
** Copyright 2008-2010 Marisa Heit
** Copyright 2020 Petr Mrazek
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

#if defined __linux__ && defined HAVE_SYSTEM_MIDI

#include <array>
#include <thread>
#include <mutex>
#include <condition_variable>

#include "mididevice.h"
#include "zmusic/mus2midi.h"
#include "zmusic_internal.h"

#include "music_alsa_state.h"
#include <alsa/asoundlib.h>

class AlsaMIDIDevice : public MIDIDevice
{
public:
	AlsaMIDIDevice(int dev_id, bool precache);
	~AlsaMIDIDevice();
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
	bool FakeVolume() override { return true; }; //Not sure if we even can control the volume this way with Alsa, so make it fake.
	bool Pause(bool paused) override;
	void InitPlayback() override;
	bool Update() override;
	bool CanHandleSysex() const override { return true; } //Assume we can, let Alsa sort it out.
	void PrecacheInstruments(const uint16_t *instruments, int count) override;

protected:
	bool PullEvent();
	void PlayerLoop();
	void HandleEvent(snd_seq_event_t &event, uint tick);

	AlsaSequencer &sequencer;
	MidiHeader *Events = nullptr;
	snd_seq_event_t Event;
	snd_midi_event_t* Coder = nullptr;
	uint32_t Position = 0;
	uint32_t PositionOffset;
	uint NextEventTickDelta;

	const static int IntendedPortId = 0;
	bool Connected = false;
	int PortId = -1;
	int QueueId = -1;

	int DestinationClientId;
	int DestinationPortId;
	int Technology;
	bool Precache;

	int InitialTempo = 480000;
	int Tempo;
	int TimeDiv = 480;

	std::thread PlayerThread;
	volatile bool Exit = false;
	std::mutex Mutex;
	std::condition_variable ExitCond;
};

AlsaMIDIDevice::AlsaMIDIDevice(int dev_id, bool precache) : sequencer(AlsaSequencer::Get())
{
	auto & internalDevices = sequencer.GetInternalDevices();
	auto & device = internalDevices.at(dev_id);
	DestinationClientId = device.ClientID;
	DestinationPortId = device.PortNumber;
	Precache = precache;
	Technology = device.GetDeviceClass();
}

AlsaMIDIDevice::~AlsaMIDIDevice()
{
	Close();
}

int AlsaMIDIDevice::Open()
{
	if (!sequencer.IsOpen())
	{
		return 1;
	}

	if (PortId < 0)
	{
		snd_seq_port_info_t *pinfo;
		snd_seq_port_info_alloca(&pinfo);

		snd_seq_port_info_set_port(pinfo, IntendedPortId);
		snd_seq_port_info_set_port_specified(pinfo, 1);

		snd_seq_port_info_set_name(pinfo, "ZMusic Program Music");

		snd_seq_port_info_set_capability(pinfo, 0);
		snd_seq_port_info_set_type(pinfo, SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION);

		snd_midi_event_new(3, &Coder); // 3 Bytes for short messages.
		snd_midi_event_init(Coder);
		snd_seq_ev_clear(&Event);

		int err = 0;
		err = snd_seq_create_port(sequencer.handle, pinfo);
		if (err) { return err; }
		PortId = IntendedPortId;
	}

	if (QueueId < 0)
	{
		QueueId = snd_seq_alloc_named_queue(sequencer.handle, "ZMusic Program Queue");
	}

	if (!Connected)
	{
		Connected = (snd_seq_connect_to(sequencer.handle, PortId, DestinationClientId, DestinationPortId) == 0);
	}
	return 0;
}

void AlsaMIDIDevice::Close()
{
	if (Connected)
	{
		snd_seq_disconnect_to(sequencer.handle, PortId, DestinationClientId, DestinationPortId);
		Connected = false;
	}
	if (QueueId >= 0)
	{
		snd_seq_free_queue(sequencer.handle, QueueId);
		QueueId = -1;
	}
	if (PortId >= 0)
	{
		snd_seq_delete_port(sequencer.handle, PortId);
		PortId = -1;
	}
	if (Coder)
	{
		snd_midi_event_free(Coder);
		Coder = nullptr;
	}
}

bool AlsaMIDIDevice::IsOpen() const
{
	return Connected;
}

int AlsaMIDIDevice::GetTechnology() const
{
	return Technology;
}

int AlsaMIDIDevice::SetTempo(int tempo)
{
	InitialTempo = tempo;
	return 0;
}

int AlsaMIDIDevice::SetTimeDiv(int timediv)
{
	TimeDiv = timediv;
	return 0;
}

// This is meant to mirror WinMIDIDevice::PrecacheInstruments
void AlsaMIDIDevice::PrecacheInstruments(const uint16_t *instruments, int count)
{
	// Setting snd_midiprecache to false disables this precaching, since it
	// does involve sleeping for more than a miniscule amount of time.
	if (!Precache)
	{
		return;
	}
	uint8_t bank[16] = {0};
	uint8_t i, chan;
	std::array<uint8_t, 3> message;

	for (i = 0, chan = 0; i < count; ++i)
	{
		uint8_t instr = instruments[i] & 127;
		uint8_t banknum = (instruments[i] >> 7) & 127;
		uint8_t percussion = instruments[i] >> 14;

		if (percussion)
		{
			if (bank[9] != banknum)
			{
				message = { MIDI_CTRLCHANGE | 9, 0, banknum };
				snd_midi_event_encode(Coder, message.data(), 3, &Event);
				HandleEvent(Event, 0);
				bank[9] = banknum;
			}
			message = { MIDI_NOTEON | 9, instr, 1 };
			snd_midi_event_encode(Coder, message.data(), 3, &Event);
			HandleEvent(Event, 0);
		}
		else
		{ // Melodic
			if (bank[chan] != banknum)
			{
				message = { MIDI_CTRLCHANGE | 9, 0, banknum };
				snd_midi_event_encode(Coder, message.data(), 3, &Event);
				HandleEvent(Event, 0);
				bank[chan] = banknum;
			}
			message = { (uint8_t)(MIDI_PRGMCHANGE | chan), (uint8_t)instruments[i] };
			snd_midi_event_encode(Coder, message.data(), 2, &Event);
			HandleEvent(Event, 0);
			message = { (uint8_t)(MIDI_NOTEON | chan), 60, 1 };
			snd_midi_event_encode(Coder, message.data(), 3, &Event);
			HandleEvent(Event, 0);
			if (++chan == 9)
			{ // Skip the percussion channel
				chan = 10;
			}
		}
		// Once we've got an instrument playing on each melodic channel, sleep to give
		// the driver time to load the instruments. Also do this for the final batch
		// of instruments.
		if (chan == 16 || i == count - 1)
		{
			std::this_thread::sleep_for(std::chrono::milliseconds(250));
			for (chan = 15; chan-- != 0; )
			{
				// Turn all notes off
				message = { (uint8_t)(MIDI_CTRLCHANGE | chan), 123, 0 };
				snd_midi_event_encode(Coder, message.data(), 3, &Event);
				HandleEvent(Event, 0);
			}
			// And now chan is back at 0, ready to start the cycle over.
		}
	}
	// Make sure all channels are set back to bank 0.
	for (i = 0; i < 16; ++i)
	{
		if (bank[i] != 0)
		{
			message = { MIDI_CTRLCHANGE | 9, 0, 0 };
			snd_midi_event_encode(Coder, message.data(), 3, &Event);
			HandleEvent(Event, 0);
		}
	}
	// Wait until all events are processed
	snd_seq_sync_output_queue(sequencer.handle);
}

bool AlsaMIDIDevice::PullEvent()
{
	if (!Events && Callback)
	{	// No events in the current MidiHeader, request next buffer
		Callback(CallbackData);
	}

	if (!Events)
	{	// No events available to process.
		return false;
	}

	if (Position >= Events->dwBytesRecorded)
	{	// All events in the "Events" buffer were used, point to next buffer
		Events = Events->lpNext;
		Position = 0;
		if (Callback != NULL)
		{	// This ensures that we always have 2 unused buffers after 1 is used up.
			// omit this nested "if" block if you want to use up the 2 buffers before requesting new buffers
			Callback(CallbackData);
		}
	}

	if (!Events)
	{	// No events in the new buffer
		return false;
	}

	uint32_t *event = (uint32_t *)(Events->lpData + Position);
	NextEventTickDelta = event[0];

	// Get event size to advance Position
	if (event[2] < 0x80000000)
	{	// Short message
		PositionOffset = 12;
	}
	else
	{	// Long message
		PositionOffset = 12 + ((MEVENT_EVENTPARM(event[2]) + 3) & ~3);
	}

	// Pulling event out of buffer
	switch (MEVENT_EVENTTYPE(event[2]))
	{
	case MEVENT_TEMPO:
	{
		int tempo = MEVENT_EVENTPARM(event[2]);
		snd_seq_ev_set_queue_tempo(&Event, QueueId, tempo);
		break;
	}
	case MEVENT_LONGMSG: // SysEx messages...
	{
		uint8_t* data = (uint8_t *)&event[3];
		int len = MEVENT_EVENTPARM(event[2]);
		if (len > 2 && data[0] == 0xF0 && data[len - 1] == 0xF7)
		{
			snd_seq_ev_set_sysex(&Event, len, (void*)data);
			break;
		}
	}
	case MEVENT_SHORTMSG:
	{
		uint8_t status = event[2] & 0xFF;
		uint8_t param1 = (event[2] >> 8) & 0x7f;
		uint8_t param2 = (event[2] >> 16) & 0x7f;
		uint8_t message[] = {status, param1, param2};
		// This silently ignore extra bytes, so no message length logic is needed.
		snd_midi_event_encode(Coder, message, 3, &Event);
		break;
	}
	default: // We didn't really recognize the event, treat it as a NOP
		Event.type = SND_SEQ_EVENT_NONE;
		snd_seq_ev_set_fixed(&Event);
	}
	return true;
}

/*
 * Pumps events from the input to the output in a worker thread.
 * It tries to keep the amount of events (time-wise) in the ALSA sequencer queue to be between 40 and 80ms by sleeping where necessary.
 * This means Alsa can play them safely without running out of things to do, and we have good control over the events themselves (volume, pause, etc.).
 */
void AlsaMIDIDevice::PlayerLoop()
{
	std::unique_lock<std::mutex> lock(Mutex);
	const std::chrono::microseconds buffer_step(40000);

	// TODO: fill in error handling throughout this.
	snd_seq_queue_tempo_t *tempo;
	snd_seq_queue_tempo_alloca(&tempo);
	snd_seq_queue_tempo_set_tempo(tempo, InitialTempo);
	snd_seq_queue_tempo_set_ppq(tempo, TimeDiv);
	snd_seq_set_queue_tempo(sequencer.handle, QueueId, tempo);

	snd_seq_start_queue(sequencer.handle, QueueId, NULL);
	snd_seq_drain_output(sequencer.handle);

	Tempo = InitialTempo;
	int buffered_ticks = 0;

	snd_seq_queue_status_t *status;
	snd_seq_queue_status_malloc(&status);

	while (!Exit)
	{
		// if we reach the end of events, await our doom at a steady rate while looking for more events
		if (!PullEvent())
		{
			ExitCond.wait_for(lock, buffer_step);
			continue;
		}

		// Figure out if we should sleep (the event is too far in the future for us to care), and for how long
		int next_event_tick = buffered_ticks + NextEventTickDelta;
		snd_seq_get_queue_status(sequencer.handle, QueueId, status);
		int queue_tick = snd_seq_queue_status_get_tick_time(status);
		int tick_delta = next_event_tick - queue_tick;
		auto usecs = std::chrono::microseconds(tick_delta * Tempo / TimeDiv);
		auto schedule_time = std::max(std::chrono::microseconds(0), usecs - buffer_step);
		if (schedule_time >= buffer_step)
		{
			ExitCond.wait_for(lock, schedule_time);
			continue;
		}
		if (tick_delta < 0)
		{	// Can be triggered on rare occasions on playback start.
			// Message shouldn't be shown by default like other midi backends here.
			ZMusic_Printf(ZMUSIC_MSG_NOTIFY, "Alsa sequencer underrun: %d ticks!\n", tick_delta);
		}

		// We found an event worthy of sending to the sequencer
		HandleEvent(Event, next_event_tick);
		buffered_ticks = next_event_tick;
		Position += PositionOffset;
	}

	snd_seq_ev_clear(&Event); // Event is cleared to be used in reset messages in Stop()
	snd_seq_queue_status_free(status);
}

// Requires QueueId to be started first for non-zero tick position
void AlsaMIDIDevice::HandleEvent(snd_seq_event_t &event, uint tick)
{
	snd_seq_ev_set_source(&event, PortId);
	snd_seq_ev_set_subs(&event);
	if (event.type == SND_SEQ_EVENT_TEMPO)
	{
		Tempo = event.data.queue.param.value;
		event.dest.client = SND_SEQ_CLIENT_SYSTEM;
		event.dest.port = SND_SEQ_PORT_SYSTEM_TIMER;
	}
	snd_seq_ev_schedule_tick(&event, QueueId, false, tick);
	int result = snd_seq_event_output(sequencer.handle, &event);
	if (result < 0)
	{
		ZMusic_Printf(ZMUSIC_MSG_ERROR, "Alsa sequencer did not accept event: error %d!\n", result);
	}
	snd_seq_drain_output(sequencer.handle);
	snd_seq_ev_clear(&event);
}


int AlsaMIDIDevice::Resume()
{
	if (!Connected || PlayerThread.joinable())
	{
		return 1;
	}
	Exit = false;
	PlayerThread = std::thread(&AlsaMIDIDevice::PlayerLoop, this);
	return 0;
}

void AlsaMIDIDevice::InitPlayback()
{
	Exit = false;
}

void AlsaMIDIDevice::Stop()
{
	Exit = true;
	ExitCond.notify_all();
	PlayerThread.join();
	snd_seq_drop_output(sequencer.handle); // This drops events in the sequencer, the sequencer is still usable

	// Reset all channels to prevent hanging notes
	for (int channel = 0; channel < 16; ++channel)
	{
		snd_seq_ev_set_controller(&Event, channel, MIDI_CTL_ALL_NOTES_OFF, 0);
		HandleEvent(Event, 0);
		snd_seq_ev_set_controller(&Event, channel, MIDI_CTL_RESET_CONTROLLERS, 0);
		HandleEvent(Event, 0);
	}
	snd_seq_sync_output_queue(sequencer.handle);
}

bool AlsaMIDIDevice::Pause(bool paused)
{
	// TODO: implement
	return false;
}


int AlsaMIDIDevice::StreamOut(MidiHeader *header)
{
	header->lpNext = NULL;
	if (Events == NULL)
	{
		Events = header;
		Position = 0;
	}
	else
	{
		MidiHeader **p;

		for (p = &Events; *p != NULL; p = &(*p)->lpNext)
		{ }
		*p = header;
	}
	return 0;
}


int AlsaMIDIDevice::StreamOutSync(MidiHeader *header)
{
	return StreamOut(header);
}

bool AlsaMIDIDevice::Update()
{
	return true;
}

MIDIDevice *CreateAlsaMIDIDevice(int mididevice)
{
	return new AlsaMIDIDevice(mididevice, miscConfig.snd_midiprecache);
}
#endif
