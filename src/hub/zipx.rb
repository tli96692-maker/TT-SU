# SU 中枢 · 标准库 ZIP 解压：store / deflate，包括 data descriptor ZIP。
require 'zlib'
require 'fileutils'

module SUHub
  module ZipX
    module_function
    EOCD_SIG = "PK\x05\x06".b
    CEN_SIG = "PK\x01\x02".b
    LOC_SIG = "PK\x03\x04".b
    MAX_ARCHIVE = 512 * 1024 * 1024
    MAX_FILE = 512 * 1024 * 1024
    MAX_TOTAL = 1024 * 1024 * 1024
    MAX_ENTRIES = 30_000

    def extract(zip_path, dest)
      raise '压缩包超过 512 MB' if File.size(zip_path) > MAX_ARCHIVE
      data = File.binread(zip_path)
      eocd = data.rindex(EOCD_SIG)
      raise '无效的 ZIP 中央目录' unless eocd && eocd + 22 <= data.bytesize
      disk, central_disk, disk_count, count, central_size, central_offset, comment_size = data.byteslice(eocd + 4, 18).unpack('vvvvVVv')
      raise '不支持分卷或 ZIP64 压缩包' unless disk.zero? && central_disk.zero? && disk_count == count && count != 65_535 && central_offset != 0xffffffff
      raise 'ZIP 目录尺寸无效' unless eocd + 22 + comment_size == data.bytesize && central_offset + central_size == eocd
      raise 'ZIP 文件数量过多' if count > MAX_ENTRIES
      FileUtils.mkdir_p(dest)
      seen = {}
      total = 0
      cursor = central_offset
      count.times do
        raise '中央目录损坏' unless data.byteslice(cursor, 4) == CEN_SIG && cursor + 46 <= eocd
        flags, method = data.byteslice(cursor + 8, 4).unpack('vv')
        crc, compressed_size, size = data.byteslice(cursor + 16, 12).unpack('VVV')
        name_len, extra_len, note_len, entry_disk = data.byteslice(cursor + 28, 8).unpack('vvvv')
        attributes, local_offset = data.byteslice(cursor + 38, 8).unpack('VV')
        raise '不支持加密或分卷 ZIP' unless (flags & 1).zero? && entry_disk.zero?
        raise '不支持 ZIP64 条目' if [compressed_size, size, local_offset].include?(0xffffffff)
        raise '不支持 ZIP 中的符号链接' if ((attributes >> 16) & 0xf000) == 0xa000
        raise "不支持的压缩方式：#{method}" unless [0, 8].include?(method)
        raise 'ZIP 条目尺寸越界' if size > MAX_FILE || (total += size) > MAX_TOTAL
        name = data.byteslice(cursor + 46, name_len).to_s.force_encoding('UTF-8')
        raise 'ZIP 文件名编码无效' unless name.valid_encoding?
        safe = safe_join(dest, name)
        raise "ZIP 包含不安全路径：#{name}" unless safe
        key = safe.downcase
        raise "ZIP 存在重复路径：#{name}" if seen[key]
        seen[key] = true
        raise '本地文件头损坏' unless data.byteslice(local_offset, 4) == LOC_SIG && local_offset + 30 <= central_offset
        local_flags, local_method = data.byteslice(local_offset + 6, 4).unpack('vv')
        local_name_len, local_extra_len = data.byteslice(local_offset + 26, 4).unpack('vv')
        raise '本地文件头不匹配' unless local_flags == flags && local_method == method && data.byteslice(local_offset + 30, local_name_len) == name.b
        start = local_offset + 30 + local_name_len + local_extra_len
        raise 'ZIP 条目数据越界' if start + compressed_size > central_offset
        ensure_no_symlinks(dest, safe)
        if name.end_with?('/', '\\')
          raise 'ZIP 目录包含数据' unless size.zero?
          FileUtils.mkdir_p(safe)
        else
          raw = data.byteslice(start, compressed_size)
          content = method.zero? ? raw : inflate(raw, size)
          raise "ZIP 文件尺寸不匹配：#{name}" unless content.bytesize == size
          raise "ZIP CRC 校验失败：#{name}" unless Zlib.crc32(content) == crc
          FileUtils.mkdir_p(File.dirname(safe))
          File.binwrite(safe, content)
        end
        cursor += 46 + name_len + extra_len + note_len
        raise '中央目录记录越界' if cursor > eocd
      end
      raise '中央目录记录数不匹配' unless cursor == eocd
      dest
    end

    def inflate(raw, expected_size = MAX_FILE)
      inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
      output = ''.b
      inflater.inflate(raw) do |chunk|
        output << chunk
        raise 'ZIP 解压大小超过声明' if output.bytesize > expected_size
      end
      output << inflater.finish
      raise 'ZIP deflate 数据不完整' unless inflater.finished? && inflater.total_in == raw.bytesize
      raise 'ZIP 解压大小超过声明' if output.bytesize > expected_size
      output
    ensure
      inflater&.close
    end

    def safe_join(dest, name)
      return nil unless name.is_a?(String) && name.valid_encoding?
      cleaned = name.tr('\\', '/')
      return nil if cleaned.empty? || cleaned.start_with?('/') || cleaned.include?("\0") || cleaned.include?(':')
      parts = cleaned.sub(%r{/\z}, '').split('/', -1)
      return nil if parts.any? { |part| part.empty? || %w[. ..].include?(part) || part.match?(/[. ]\z|\A(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|\z)/i) }
      root = File.expand_path(dest)
      result = File.expand_path(File.join(root, *parts))
      result.start_with?(root + File::SEPARATOR) ? result : nil
    end

    def ensure_no_symlinks(dest, target)
      root = File.expand_path(dest)
      path = target
      loop do
        raise '解压目标含符号链接' if File.symlink?(path)
        break if path == root
        parent = File.dirname(path)
        raise '解压目标越界' if parent == path
        path = parent
      end
    end
  end
end
