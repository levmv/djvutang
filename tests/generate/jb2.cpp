/* Generate padded-symbol fixtures with DjVuLibre's modern and legacy encoders.
Requires libdjvulibre-dev and the matching DjVuLibre source headers:
c++ -std=c++11 -DHAVE_NAMESPACES -DHAVE_STDINT_H \
    -DHAS_WCHAR -DHAS_WCTYPE -DHAS_MBSTATE -I/path/to/djvulibre/libdjvu \
    tests/generate/jb2.cpp -ldjvulibre -o /tmp/djvutang-jb2-fixtures
/tmp/djvutang-jb2-fixtures tests/fixtures
Normal builds and tests use the saved files, without this tool or DjVuLibre.
*/
#include "ByteStream.h"
#include "GBitmap.h"
#include "JB2Image.h"
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

using namespace DJVU;

constexpr int width = 64, height = 48;
constexpr int symbol_width = 7, symbol_height = 9;
constexpr int positions[][2] = {{5, 33}, {20, 33}, {35, 33}, {5, 18}, {20, 18}, {5, 3}};

bool ink(int x, int y) {
    return (x == 2 && y >= 2 && y <= 7) ||
           (x >= 2 && x <= 5 && (y == 2 || y == 5 || y == 7));
}

void uint32(std::ostream &out, unsigned value) {
    for (int shift = 24; shift >= 0; shift -= 8) out.put((value >> shift) & 255);
}

void write_page(const std::string &path, bool legacy) {
    auto image = JB2Image::create();
    image->set_dimension(width, height);
    image->reproduce_old_bug = legacy;
    JB2Shape shape{};
    shape.parent = -1;
    shape.bits = GBitmap::create(symbol_height, symbol_width);
    for (int y = 0; y < symbol_height; ++y)
        for (int x = 0; x < symbol_width; ++x) (*shape.bits)[y][x] = ink(x, y);
    const auto index = image->add_shape(shape);
    for (const auto &position : positions) {
        JB2Blit blit{};
        blit.shapeno = index;
        blit.left = position[0];
        blit.bottom = position[1];
        image->add_blit(blit);
    }
    auto stream = ByteStream::create();
    image->encode(stream);
    std::vector<char> payload(stream->tell());
    stream->seek(0);
    stream->readall(payload.data(), payload.size());

    std::ofstream out(path, std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    out.write("AT&TFORM", 8);
    uint32(out, 4 + 14 + 8 + payload.size() + payload.size() % 2);
    out.write("DJVUINFO", 8);
    uint32(out, 5);
    out.put(0).put(width).put(0).put(height).put(legacy ? 17 : 19).put(0);
    out.write("Sjbz", 4);
    uint32(out, payload.size());
    out.write(payload.data(), payload.size());
    if (payload.size() % 2) out.put(0);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        std::cerr << "Usage: " << argv[0] << " OUTPUT_DIRECTORY\n";
        return 1;
    }
    const std::string prefix = std::string(argv[1]) + "/jb2-padded";
    write_page(prefix + "-legacy.djvu", true);
    write_page(prefix + "-modern.djvu", false);

    // Reference pixels come directly from our geometry, without decoding JB2.
    std::vector<unsigned char> pixels(width / 8 * height, 0);
    for (const auto &position : positions)
        for (int y = 0; y < symbol_height; ++y)
            for (int x = 0; x < symbol_width; ++x) if (ink(x, y)) {
                const int px = position[0] + x, py = height - 1 - position[1] - y;
                pixels[py * (width / 8) + px / 8] |= 128 >> (px % 8);
            }
    std::ofstream out(prefix + ".pbm", std::ios::binary);
    out.exceptions(std::ios::failbit | std::ios::badbit);
    out << "P4\n" << width << ' ' << height << '\n';
    out.write(reinterpret_cast<const char *>(pixels.data()), pixels.size());
}
