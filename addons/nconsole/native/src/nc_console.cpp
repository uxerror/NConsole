#include "nc_console.h"

#include "nc_state.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>

using namespace godot;

NConsole::NConsole() {
	cpu.instantiate();
	video.instantiate();
	audio.instantiate();
	cpu->device = this;
	audio->clock_hz = CLOCK_HZ;
	audio->sample_rate = SAMPLE_RATE;
	pads.resize(2);
	pads.fill(0);
}

NConsole::~NConsole() {
	cpu->device = nullptr; // someone may still hold the CPU
}

void NConsole::insert(const Ref<NCCartridge> &cart) {
	cartridge = cart;
	video->load_tiles(cart.is_valid() ? cart->chr : PackedByteArray());
	cpu->clear_memory();
	cpu->_set_sram_size(cart.is_valid() ? cart->sram_size : 0);
	cpu->sram_dirty = false;
	reset();
}

// Power cycle: RAM cleared (save RAM kept), ROM mapped, CPU through its
// reset vector.
void NConsole::reset() {
	const PackedByteArray kept = get_save_ram();
	cpu->clear_memory();
	cpu->load_memory(NCCpu::SRAM_START, kept);
	if (cartridge.is_valid()) {
		cpu->load_memory(0xC000, cartridge->bank(cartridge->get_prg_banks() - 1));
	}
	map_bank(0);
	in_frame = false;
	video->set_chr_bank(0);
	frame = 0;
	vctrl = 0x03;
	bg_color = 0;
	scroll_x = scroll_y = 0;
	fixed_rows = 0;
	rng = 0xACE1;
	debug_log = "";
	audio->reset();
	cpu->reset();
	redraw = true;
}

// Runs one frame, or the rest of the current one. Stops early, and
// pauses, at a breakpoint or watched write.
void NConsole::run_frame() {
	if (paused) {
		return;
	}
	if (!in_frame) {
		begin_frame();
	}
	const int64_t used = cpu->run(left);
	left -= used;
	last_cycles += used;
	if (!cpu->stop_reason.is_empty()) {
		paused = true;
		return;
	}
	end_frame();
}

// Runs one instruction, for the debugger. A CPU waiting for the next frame
// ends this one first (picture, sound), then wakes in the next.
void NConsole::step_instruction() {
	if (!in_frame) {
		begin_frame();
	}
	if (cpu->halted) {
		return;
	}
	if (cpu->waiting || left <= 0) {
		end_frame();
		begin_frame();
	}
	const int64_t before = cpu->cycles;
	cpu->resume(); // step over a breakpoint we are stopped at
	cpu->record_trace();
	cpu->step();
	left -= cpu->cycles - before;
	last_cycles += cpu->cycles - before;
}

void NConsole::set_pad(int index, int buttons) {
	if (index >= 0 && index < pads.size()) {
		pads.set(index, buttons & 0xFF);
	}
}

// Goes on after a stop.
void NConsole::resume() {
	paused = false;
	cpu->resume();
}

// Draws video RAM now, for a debugger looking at a frame in progress.
void NConsole::render_now() {
	video->render(cpu->memory_data(), vctrl & 1, vctrl & 2, bg_color, scroll_x, scroll_y, fixed_rows);
	cpu->vram_dirty = false;
}

PackedByteArray NConsole::get_save_ram() const {
	PackedByteArray out;
	out.resize(cpu->sram_size);
	for (int k = 0; k < cpu->sram_size; k++) {
		out.set(k, cpu->peek(NCCpu::SRAM_START + k));
	}
	return out;
}

// Fills the save RAM from data; what it doesn't cover is zero.
void NConsole::set_save_ram(const PackedByteArray &data) {
	for (int k = 0; k < cpu->sram_size; k++) {
		cpu->poke(NCCpu::SRAM_START + k, k < data.size() ? data[k] : 0);
	}
	cpu->sram_dirty = false;
}

namespace {
const char STATE_MAGIC[4] = { 'N', 'C', 'S', 0x1A };
constexpr int STATE_VERSION = 1;
} // namespace

PackedByteArray NConsole::save_state() const {
	NCStateWriter w;
	w.bytes(STATE_MAGIC, 4);
	w.u8(STATE_VERSION);
	w.i64(cartridge.is_valid() ? cartridge->rom_hash() : 0);
	// The CPU, and memory below the ROM (the ROM comes from the cartridge).
	w.u8(cpu->a);
	w.u8(cpu->x);
	w.u8(cpu->y);
	w.u8(cpu->sp);
	w.i32(cpu->pc);
	w.u8(cpu->flags());
	w.u8(cpu->waiting);
	w.u8(cpu->halted);
	w.i64(cpu->cycles);
	w.bytes(cpu->memory_data(), NCCpu::ROM_START);
	// The console.
	w.i32(frame);
	w.u8(vctrl);
	w.u8(bg_color);
	w.u8(scroll_x);
	w.u8(scroll_y);
	w.u8(fixed_rows);
	w.u8(prg_bank);
	w.u8(video->get_chr_bank());
	w.u8(pads[0]);
	w.u8(pads[1]);
	w.i32(rng);
	w.u8(in_frame);
	w.i64(frame_start);
	w.i64(left);
	w.i64(last_cycles);
	audio->save_state(w);
	return w.out;
}

bool NConsole::load_state(const PackedByteArray &data) {
	NCStateReader r(data);
	char magic[4];
	r.bytes(magic, 4);
	if (r.failed || std::memcmp(magic, STATE_MAGIC, 4) != 0 || r.u8() != STATE_VERSION) {
		return false;
	}
	if (cartridge.is_null() || r.i64() != cartridge->rom_hash()) {
		return false;
	}
	// Read it all first, to change nothing if it's cut short.
	const int a = r.u8(), x = r.u8(), y = r.u8(), sp = r.u8();
	const int pc = r.i32() & 0xFFFF;
	const int f = r.u8();
	const bool waiting = r.u8(), halted = r.u8();
	const int64_t cycles = r.i64();
	PackedByteArray ram;
	ram.resize(NCCpu::ROM_START);
	r.bytes(ram.ptrw(), ram.size());
	const int p_frame = r.i32() & 0xFFFF;
	const int p_vctrl = r.u8(), p_bg = r.u8() & 15, p_sx = r.u8(), p_sy = r.u8(), p_fixed = r.u8() & 15;
	const int p_bank = r.u8(), p_chr = r.u8(), pad0 = r.u8(), pad1 = r.u8();
	const int p_rng = r.i32();
	const bool p_in_frame = r.u8();
	const int64_t p_frame_start = r.i64(), p_left = r.i64(), p_last = r.i64();
	NCStateWriter backup;
	audio->save_state(backup);
	audio->load_state(r);
	if (!r.done()) {
		NCStateReader undo(backup.out);
		audio->load_state(undo);
		return false;
	}

	cpu->a = a;
	cpu->x = x;
	cpu->y = y;
	cpu->sp = sp;
	cpu->pc = pc;
	cpu->set_flags(f);
	cpu->waiting = waiting;
	cpu->halted = halted;
	cpu->cycles = cycles;
	cpu->load_memory(0, ram);
	cpu->load_memory(0xC000, cartridge->bank(cartridge->get_prg_banks() - 1));
	map_bank(p_bank % cartridge->get_prg_banks());
	frame = p_frame;
	vctrl = p_vctrl;
	bg_color = p_bg;
	scroll_x = p_sx;
	scroll_y = p_sy;
	fixed_rows = p_fixed;
	video->set_chr_bank(p_chr % cartridge->get_chr_banks());
	pads.set(0, pad0);
	pads.set(1, pad1);
	rng = p_rng;
	in_frame = p_in_frame;
	frame_start = p_frame_start;
	left = p_left;
	last_cycles = p_last;
	sound = PackedVector2Array();
	cpu->sram_dirty = true; // the save RAM may differ from what was kept
	render_now();
	return true;
}

void NConsole::begin_frame() {
	in_frame = true;
	frame_start = cpu->cycles;
	left = CYCLES_PER_FRAME;
	last_cycles = 0;
	cpu->vblank(vctrl & 0x80);
}

void NConsole::end_frame() {
	in_frame = false;
	sound = audio->mix(SAMPLES_PER_FRAME);
	frame = (frame + 1) & 0xFFFF;
	next_random(); // the sequence also depends on when the program reads it
	if (redraw || cpu->vram_dirty) {
		render_now();
		redraw = false;
	}
}

// Puts program bank n at $8000-$BFFF.
void NConsole::map_bank(int n) {
	prg_bank = n;
	if (cartridge.is_valid()) {
		cpu->load_memory(0x8000, cartridge->bank(n));
	}
}

int NConsole::next_random() {
	// 16-bit Galois LFSR.
	const int bit = rng & 1;
	rng >>= 1;
	if (bit) {
		rng ^= 0xB400;
	}
	return rng & 0xFF;
}

int NConsole::read_io(int reg) {
	switch (reg) {
		case REG_VCTRL: return vctrl;
		case REG_BGCOLOR: return bg_color;
		case REG_SCROLLX: return scroll_x;
		case REG_SCROLLY: return scroll_y;
		case REG_FIXROWS: return fixed_rows;
		case REG_PRGBANK: return prg_bank;
		case REG_CHRBANK: return video->get_chr_bank();
		case REG_PAD1: return pads.size() > 0 ? pads[0] : 0;
		case REG_PAD2: return pads.size() > 1 ? pads[1] : 0;
		case REG_SOUND_END: return audio->status();
		case REG_FRAME: return frame & 0xFF;
		case REG_FRAMEHI: return frame >> 8;
		case REG_RANDOM:
			for (int k = 0; k < 8; k++) {
				next_random();
			}
			return rng & 0xFF;
	}
	return 0;
}

void NConsole::write_io(int reg, int value) {
	switch (reg) {
		case REG_VCTRL:
			if ((vctrl ^ value) & 3) {
				redraw = true;
			}
			vctrl = value;
			break;
		case REG_BGCOLOR:
			bg_color = value & 15;
			redraw = true;
			break;
		case REG_SCROLLX:
			scroll_x = value;
			redraw = true;
			break;
		case REG_SCROLLY:
			scroll_y = value;
			redraw = true;
			break;
		case REG_FIXROWS:
			fixed_rows = value & 15;
			redraw = true;
			break;
		case REG_PRGBANK:
			if (cartridge.is_valid()) {
				map_bank(value % cartridge->get_prg_banks());
			}
			break;
		case REG_CHRBANK:
			if (cartridge.is_valid()) {
				video->set_chr_bank(value % cartridge->get_chr_banks());
				redraw = true;
			}
			break;
		case REG_DEBUG:
			debug_log += String::chr(value);
			break;
		default:
			if (reg >= REG_SOUND && reg <= REG_SOUND_END) {
				// At the sample matching the cycle of the write.
				const int64_t at = (cpu->cycles - frame_start) * SAMPLES_PER_FRAME / CYCLES_PER_FRAME;
				audio->write(reg - REG_SOUND, value, (int)std::clamp<int64_t>(at, 0, SAMPLES_PER_FRAME - 1));
			}
	}
}

void NConsole::_bind_methods() {
	ClassDB::bind_method(D_METHOD("insert", "cartridge"), &NConsole::insert);
	ClassDB::bind_method(D_METHOD("reset"), &NConsole::reset);
	ClassDB::bind_method(D_METHOD("run_frame"), &NConsole::run_frame);
	ClassDB::bind_method(D_METHOD("step_instruction"), &NConsole::step_instruction);
	ClassDB::bind_method(D_METHOD("resume"), &NConsole::resume);
	ClassDB::bind_method(D_METHOD("render_now"), &NConsole::render_now);
	ClassDB::bind_method(D_METHOD("get_save_ram"), &NConsole::get_save_ram);
	ClassDB::bind_method(D_METHOD("set_save_ram", "data"), &NConsole::set_save_ram);
	ADD_PROPERTY(PropertyInfo(Variant::PACKED_BYTE_ARRAY, "save_ram", PROPERTY_HINT_NONE, "", PROPERTY_USAGE_NONE), "set_save_ram", "get_save_ram");
	ClassDB::bind_method(D_METHOD("save_state"), &NConsole::save_state);
	ClassDB::bind_method(D_METHOD("load_state", "data"), &NConsole::load_state);
	ClassDB::bind_method(D_METHOD("set_pad", "index", "buttons"), &NConsole::set_pad);
	ClassDB::bind_method(D_METHOD("read_io", "reg"), &NConsole::read_io);
	ClassDB::bind_method(D_METHOD("write_io", "reg", "value"), &NConsole::write_io);

#define NC_PROPERTY(type, name, hint)                                                    \
	ClassDB::bind_method(D_METHOD("_get_" #name), &NConsole::_get_##name);               \
	ClassDB::bind_method(D_METHOD("_set_" #name, "value"), &NConsole::_set_##name);    \
	ADD_PROPERTY(PropertyInfo(Variant::type, #name, PROPERTY_HINT_RESOURCE_TYPE, hint), "_set_" #name, "_get_" #name);
	// The parts are objects the console makes itself: not saved, not shown
	// in the inspector. Without PROPERTY_USAGE_NONE the editor would keep
	// a console's parts as "default values" until after the extension is
	// unloaded, and crash freeing them on exit.
#define NC_PART(name, type)                                                              \
	ClassDB::bind_method(D_METHOD("_get_" #name), &NConsole::_get_##name);               \
	ClassDB::bind_method(D_METHOD("_set_" #name, "value"), &NConsole::_set_##name);    \
	ADD_PROPERTY(PropertyInfo(Variant::OBJECT, #name, PROPERTY_HINT_RESOURCE_TYPE, type, PROPERTY_USAGE_NONE), "_set_" #name, "_get_" #name);
	NC_PART(cpu, "NCCpu")
	NC_PART(video, "NCVideo")
	NC_PART(audio, "NCAudio")
	NC_PART(cartridge, "NCCartridge")
#undef NC_PART
	NC_PROPERTY(PACKED_VECTOR2_ARRAY, sound, "")
	NC_PROPERTY(PACKED_BYTE_ARRAY, pads, "")
	NC_PROPERTY(INT, frame, "")
	NC_PROPERTY(INT, vctrl, "")
	NC_PROPERTY(INT, bg_color, "")
	NC_PROPERTY(INT, scroll_x, "")
	NC_PROPERTY(INT, scroll_y, "")
	NC_PROPERTY(INT, fixed_rows, "")
	NC_PROPERTY(INT, prg_bank, "")
	NC_PROPERTY(INT, last_cycles, "")
	NC_PROPERTY(STRING, debug_log, "")
	NC_PROPERTY(BOOL, paused, "")
#undef NC_PROPERTY

	BIND_CONSTANT(CLOCK_HZ);
	BIND_CONSTANT(FPS);
	BIND_CONSTANT(CYCLES_PER_FRAME);
	BIND_CONSTANT(SAMPLE_RATE);
	BIND_CONSTANT(SAMPLES_PER_FRAME);
	BIND_CONSTANT(BTN_UP);
	BIND_CONSTANT(BTN_DOWN);
	BIND_CONSTANT(BTN_LEFT);
	BIND_CONSTANT(BTN_RIGHT);
	BIND_CONSTANT(BTN_A);
	BIND_CONSTANT(BTN_B);
	BIND_CONSTANT(BTN_SELECT);
	BIND_CONSTANT(BTN_START);
	BIND_CONSTANT(REG_VCTRL);
	BIND_CONSTANT(REG_BGCOLOR);
	BIND_CONSTANT(REG_SCROLLX);
	BIND_CONSTANT(REG_SCROLLY);
	BIND_CONSTANT(REG_FIXROWS);
	BIND_CONSTANT(REG_PRGBANK);
	BIND_CONSTANT(REG_CHRBANK);
	BIND_CONSTANT(REG_PAD1);
	BIND_CONSTANT(REG_PAD2);
	BIND_CONSTANT(REG_FRAME);
	BIND_CONSTANT(REG_FRAMEHI);
	BIND_CONSTANT(REG_RANDOM);
	BIND_CONSTANT(REG_SOUND);
	BIND_CONSTANT(REG_SOUND_END);
	BIND_CONSTANT(REG_DEBUG);
}
