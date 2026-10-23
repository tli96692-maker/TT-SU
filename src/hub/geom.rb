# Shared geometry helpers. All geometry lengths are SketchUp inches.
module SUHub
  module Geom
    EPSILON = 1.0e-7 unless const_defined?(:EPSILON, false)
    module_function

    # Plain values are millimetres regardless of the model's display units.
    def parse_mm(value)
      match = /\A\s*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?)\s*(mm|cm|m|in|ft|"|')?\s*\z/i.match(value.to_s)
      raise ArgumentError, '请输入有效长度，例如 100、100mm、10cm 或 1m。' unless match
      multiplier = { nil => 1.0, 'mm' => 1.0, 'cm' => 10.0, 'm' => 1000.0, 'in' => 25.4, '"' => 25.4, 'ft' => 304.8, "'" => 304.8 }[match[2]&.downcase]
      length = Float(match[1]) * multiplier / 25.4
      raise ArgumentError, '长度必须是有限数值。' unless length.finite?
      length
    end

    def operation(model, name, rollback: false)
      operations = Thread.current[:suhub_geometry_operations] ||= {}
      if operations[model.object_id]
        raise ArgumentError, '不能在现有操作中单独回滚嵌套操作。' if rollback
        return yield
      end
      started = model.start_operation(name, true)
      raise "无法开始操作：#{name}" unless started
      operations[model.object_id] = true
      begin
        result = yield
        rollback ? model.abort_operation : model.commit_operation
        result
      rescue Exception
        model.abort_operation
        raise
      ensure
        operations.delete(model.object_id)
      end
    end

    def same_point?(a, b)
      # SketchUp Length#< applies model tolerance: even 0.to_l < 1e-7 is
      # false. Convert to Float for explicit numerical tolerance checks.
      a.distance(b).to_f < EPSILON
    end

    def clean_loop(points)
      cleaned = []
      points.each { |p| cleaned << p if cleaned.empty? || !same_point?(cleaned.last, p) }
      cleaned.pop if cleaned.size > 1 && same_point?(cleaned.first, cleaned.last)
      cleaned
    end

    def align_loops(a, b, closed)
      a = closed ? clean_loop(a) : a.dup
      b = closed ? clean_loop(b) : b.dup
      raise ArgumentError, '每条轮廓至少需要两个不同的点。' if a.size < 2 || b.size < 2
      if closed
        candidates = [b, b.reverse].flat_map { |curve| curve.size.times.map { |i| curve.rotate(i) } }
        b = candidates.min_by do |curve|
          a.each_with_index.sum { |p, i| p.distance(curve[(i * curve.size.to_f / a.size).round % curve.size]) }
        end
      else
        forward = a.first.distance(b.first) + a.last.distance(b.last)
        reverse = a.first.distance(b.last) + a.last.distance(b.first)
        b.reverse! if reverse < forward
      end
      [a, b]
    end

    def loft(ents, loop_a, loop_b, closed: false)
      a, b = align_loops(loop_a, loop_b, closed)
      raise ArgumentError, '闭合轮廓至少需要三个点。' if closed && (a.size < 3 || b.size < 3)
      a += [a.first] if closed
      b += [b.first] if closed
      i = j = 0
      faces = []
      while i < a.size - 1 || j < b.size - 1
        if i >= a.size - 1 || (j < b.size - 1 && a[i].distance(b[j + 1]) <= a[i + 1].distance(b[j]))
          faces << tri(ents, a[i], b[j + 1], b[j])
          j += 1
        else
          faces << tri(ents, a[i], a[i + 1], b[j])
          i += 1
        end
      end
      raise '轮廓之间没有生成有效曲面，请检查是否重合或相交。' if faces.empty?
      faces.flat_map(&:edges).uniq.each do |edge|
        next unless edge.faces.size == 2 && edge.faces.all? { |face| faces.include?(face) }
        edge.soft = edge.smooth = true
      end
      faces
    end

    def tri(ents, p, q, r)
      raise ArgumentError, '轮廓相交或重合，产生退化三角形。' if same_point?(p, q) || same_point?(q, r) || same_point?(r, p)
      face = ents.add_face(p, q, r)
      raise '无法建立三角面，请检查轮廓的尺寸、重合与自交。' unless face
      face
    end

    def extract_contours(edges)
      edges = edges.uniq
      adjacency = Hash.new { |h, vertex| h[vertex] = [] }
      edges.each { |edge| edge.vertices.each { |vertex| adjacency[vertex] << edge } }
      raise ArgumentError, '轮廓包含分叉点，请只选择不分叉的轮廓边线。' if adjacency.values.any? { |incident| incident.size > 2 }
      remaining = edges.each_with_object({}) { |edge, h| h[edge] = true }
      closed = []
      open = []
      until remaining.empty?
        seed = remaining.keys.first
        component = []
        queue = [seed]
        visited = {}
        until queue.empty?
          edge = queue.pop
          next if visited[edge]
          visited[edge] = true
          component << edge
          edge.vertices.each { |vertex| queue.concat(adjacency[vertex].reject { |item| visited[item] }) }
        end
        vertices = component.flat_map(&:vertices).uniq
        start = vertices.find { |vertex| adjacency[vertex].size == 1 } || seed.start
        current = start
        points = [current.position]
        loop do
          edge = adjacency[current].find { |candidate| remaining[candidate] }
          break unless edge
          remaining.delete(edge)
          current = edge.other_vertex(current)
          points << current.position
          break if current == start
        end
        raise ArgumentError, '无法完整读取轮廓。' unless component.none? { |edge| remaining[edge] }
        (current == start ? closed : open) << points
      end
      [closed, open]
    end
  end
end
