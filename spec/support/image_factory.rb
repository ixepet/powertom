# frozen_string_literal: true

require "zlib"

# 测试工具:程序化生成任意尺寸的合法 PNG(不走 base64 常量,尺寸可控以便测裁切)。
module PowerTomDev
  module ImageFactory
    module_function

    def write_png(path, width, height, rgb = [30, 144, 255])
      File.binwrite(path, png(width, height, rgb))
      path
    end

    def png(width, height, rgb = [30, 144, 255])
      signature = [137, 80, 78, 71, 13, 10, 26, 10].pack("C8")
      chunk = lambda do |type, data|
        [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
      end
      ihdr = [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")
      row = ([0].pack("C")) + (rgb.pack("C3") * width)
      idat = Zlib::Deflate.deflate(row * height)
      signature + chunk.call("IHDR", ihdr) + chunk.call("IDAT", idat) + chunk.call("IEND", "")
    end
  end
end
