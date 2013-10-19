#!/usr/bin/env ruby
require 'yaml'
require 'nokogiri'

file = ARGV[0] || raise(ArgumentError, "The first command line argument must be path to state file")
state_path = File.expand_path(file)
state = YAML.load(File.read state_path)
game_path = File.expand_path("#{state["game"]}.yaml", File.dirname(state_path))
game = YAML.load(File.read game_path)

svg = Nokogiri::XML::Document.new
svg.root = svg.create_element "svg"
svg.root["viewBox"] = "0 0 #{game["size"][0]} #{game["size"][1]}"
svg.root["xmlns"] = "http://www.w3.org/2000/svg"
svg.root["xmlns:xlink"] = "http://www.w3.org/1999/xlink"

title_n = svg.create_element "title", "#{game["name"]} - #{state["date"]}"
svg.root << title_n

s = game["style"]
css = <<-CSS
  .l { fill: #{s["land_fill"]}; }
  .w { fill: #{s["water_fill"]}; }
  .l, .w {
    stroke: #{s["stroke"]};
    stroke-linejoin: #{s["stroke_linejoin"]};
  }
  text {
    font-family: #{s["font_family"]};
    font-size: #{s["font_size"]};
  }
  .unowned, .nat-#{game["nations"].keys.join(", .nat-")} {
    stroke: #{s["stroke"]};
  }
  .unowned { fill: #{s["unowned_color"]}; }
  CSS
css = "\n" + css + game["nations"].map { |nation_id, nation|
  ".nat-#{nation_id} { fill: #{nation["color"]}; }"
}.join("\n") + "\n"
style_n = svg.create_element "style", nil, "type" => "text/css"
style_n << svg.create_cdata(css)
svg.root << style_n

def create_shape_node(doc, shape_spec)
  node =
    if shape_spec["points"]
      doc.create_element "polygon", nil, "points" => shape_spec["points"]
    elsif shape_spec["path"]
      doc.create_element "path", nil, "d" => shape_spec["path"]
    elsif shape_spec["circle"]
      doc.create_element "circle", nil, "r" => shape_spec["circle"]
    else
      raise ArgumentError, "Unknown shape spec #{shape_spec.inspect}"
    end

  node["class"] = shape_spec["class"] if shape_spec["class"]
  node
end

def create_asset_node(doc, id, shape_specs)
  g_n = doc.create_element "g", nil, "id" => id
  shape_specs.each do |spec|
    g_n << create_shape_node(doc, spec)
  end
  g_n
end

svg.root << create_asset_node(svg, "A", game["asset_shapes"]["army"])
svg.root << create_asset_node(svg, "F", game["asset_shapes"]["fleet"])
svg.root << create_asset_node(svg, "SC", game["asset_shapes"]["sc"])

area_short_to_id = {}
area_by_id = {}
game["areas"].each do |area|
  area_short_to_id[area["short"] || area["id"]] = area["id"]
  area_by_id[area["id"]] = area
  raise ArgumentError, "Missing shape for #{area["id"].inspect}" \
    unless shapes = game["shapes"][area["id"]]

  g_n = svg.create_element "g", nil,
    "title" => area["name"],
    "id" => "area-#{area["id"]}"

  shapes.each do |shape|
    g_n << create_shape_node(svg, shape)
  end

  g_n << svg.create_element("text", area["short"] || area["id"], 
    "x" => area["label"][0],
    "y" => area["label"][1])

  svg.root << g_n
end

unit_by_area = {}
state["units"].each do |nation_id, units|
  units.each do |type, list|
    is_fleet =
      case type
      when "fleets"
        true
      when "armies"
        false
      else
        raise ArgumentError, "Unknown unit type #{type.inspect}"
      end
          
    list.each do |location|
      area_short, coast = *
        if location =~ /^([A-Za-z]+)\s*\(([A-Za-z]+)\)$/
          [$1, $2]
        else
          [location, nil]
        end

      area_id = area_short_to_id[area_short] ||
        raise(ArgumentError, "Unknown area #{area_short.inspect}")

      unless unit_by_area.has_key? area_id
        unit_by_area[area_id] = [nation_id, is_fleet, coast]
      else
        raise ArgumentError, "Duplicate unit for #{area_short.inspect}"
      end
    end
  end
end

unit_by_area.each do |area_id, info|
  nation_id, is_fleet, coast = *info
  point = 
    if coast
      area = area_by_id[area_id]
      area["coasts"][coast] ||
        raise(ArgumentError, "Unknown coast #{coast.inspect} of #{area["short"] || area["id"]}")
    else
      area_by_id[area_id]["point"]
    end

  g_n = svg.create_element "g", nil, "title" => area_by_id[area_id]["name"]
  use_n = svg.create_element "use", nil, 
    "xlink:href" => is_fleet ? "#F" : "#A",
    "id" => "unit-#{area_id}",
    "class" => "nat-#{nation_id}",
    "transform" => "translate(#{point[0]},#{point[1]})"
  svg.root << (g_n << use_n)
end

owner_by_sc = {}
state["scs"].each do |nation_id, list|
  list.each do |area_short|
    raise ArgumentError, "Area #{area_short.inspect} does not exist" \
      unless area_id = area_short_to_id[area_short]
    raise ArgumentError, "Area #{area_short.inspect} does not contain a supply center" \
      unless area_by_id[area_id]["sc"]
    raise ArgumentError, "Duplicate ownership for #{area_short.inspect}" \
      if owner_by_sc.has_key? area_id
    owner_by_sc[area_id] = nation_id
  end
end

area_by_id.each do |area_id, area|
  if area["sc"]
    klass = 
      if owner = owner_by_sc[area_id]
        "nat-#{owner}"
      else
        "unowned"
      end

    g_n = svg.create_element "g", nil, "title" => area["name"]
    use_n = svg.create_element "use", nil, 
      "xlink:href" => "#SC",
      "class" => klass,
      "transform" => "translate(#{area["sc"][0]},#{area["sc"][1]})"
    svg.root << (g_n << use_n)
  end
end

if ARGV[1]
  File.write(ARGV[1], svg.to_s)
else
  puts svg.to_s
end
