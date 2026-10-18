// Writing and reading a save state: plain values, little-endian, in the
// order the parts write them. A reader that runs past the end, or is told
// the data is wrong, stays failed and reads zeros.

#pragma once

#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>
#include <cstring>

namespace godot {

struct NCStateWriter {
	PackedByteArray out;

	void bytes(const void *data, int64_t n) {
		const int64_t at = out.size();
		out.resize(at + n);
		std::memcpy(out.ptrw() + at, data, n);
	}
	void u8(int v) {
		const uint8_t b = v & 0xFF;
		bytes(&b, 1);
	}
	void i32(int32_t v) { bytes(&v, sizeof(v)); }
	void i64(int64_t v) { bytes(&v, sizeof(v)); }
	void f64(double v) { bytes(&v, sizeof(v)); }
};

struct NCStateReader {
	const PackedByteArray &in;
	int64_t at = 0;
	bool failed = false;

	explicit NCStateReader(const PackedByteArray &data) :
			in(data) {}

	void bytes(void *data, int64_t n) {
		if (failed || at + n > in.size()) {
			failed = true;
			std::memset(data, 0, n);
			return;
		}
		std::memcpy(data, in.ptr() + at, n);
		at += n;
	}
	int u8() {
		uint8_t b;
		bytes(&b, 1);
		return b;
	}
	int32_t i32() {
		int32_t v;
		bytes(&v, sizeof(v));
		return v;
	}
	int64_t i64() {
		int64_t v;
		bytes(&v, sizeof(v));
		return v;
	}
	double f64() {
		double v;
		bytes(&v, sizeof(v));
		return v;
	}
	bool done() const { return !failed && at == in.size(); }
};

} // namespace godot
