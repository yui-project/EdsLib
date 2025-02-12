--
-- LEW-19710-1, CCSDS SOIS Electronic Data Sheet Implementation
--
-- Copyright (c) 2020 United States Government as represented by
-- the Administrator of the National Aeronautics and Space Administration.
-- All Rights Reserved.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--    http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--


-- -------------------------------------------------------------------------
-- This is the first part of adapting EDS to the CFE architecture / Software Bus
-- The objective of this script is to collect the "parameter" values for the
-- various component instances which exist.  To do this, it is critical to use
-- the exact same logic for mapping Topic Ids (the values specified in EDS) to
-- Message Ids (the values used by software bus for routing).
--
-- The process starts by building the code that was generated by the edslib
-- header/source generator scripts.
--
-- After this script completes, "SEDS.edslib" should be a fully-functioning
-- set of Lua bindings for the EDS objects just as it would be in an external tool,
-- and thus it can be used to instantiate EDS-described objects that will be
-- compatible with future Flight Software code.
-- -------------------------------------------------------------------------

local makefilename = SEDS.to_filename("db_objects.mk")
local objdir = SEDS.get_define("OBJDIR") or "obj"
local edsdb_basename = string.format("%s/%s", objdir, SEDS.to_filename("db"))
local missionlib_basename = string.format("%s/%s", objdir, SEDS.to_filename("missionlib_runtime"))
local edsdb_load_sym = string.upper(SEDS.get_define("MISSION_NAME") or "EDS") .. "_DATABASE"

-- ------------------------------------------------------------------
-- Step 0: determine list of targets to build here.
-- there are potentially 3 targets:
--    .a   - static link version
--    .so  - shared link version (PIC)
--    .obj - relocatable version
-- ------------------------------------------------------------------
local all_edsdb_targets = {}
for _,t in ipairs({ ".so", ".a", ".obj" }) do
  all_edsdb_targets[1 + #all_edsdb_targets] = edsdb_basename .. t
end


-- ------------------------------------------------------------------
-- Step 1: call the build tool to actually run the makefile generated by the edsdb script
--
-- This should produce a valid .a and .so file.  If this triggers any errors,
-- the script will abort.  This indicates problems in the generated source files.
-- ------------------------------------------------------------------
SEDS.execute_tool("BUILD_TOOL",
  string.format("-j1 -C %s -f %s O=\"%s\" CC=\"%s\" LD=\"%s\" AR=\"%s\" CFLAGS=\"%s\" LDFLAGS=\"%s\" %s",
    SEDS.get_define("MISSION_BINARY_DIR") or ".",
    makefilename,
    objdir,
    SEDS.get_define("CC") or "cc",
    SEDS.get_define("LD") or "ld",
    SEDS.get_define("AR") or "ar",
    SEDS.get_define("CFLAGS") or "-Wall -Werror -std=c99 -pedantic",
    SEDS.get_define("LDFLAGS") or "",
    table.concat(all_edsdb_targets," ")
  )
)

-- ------------------------------------------------------------------
-- Step 2: load the .so file just created into this running process
-- The database will be attached to the "SEDS" global as the edslib member
-- ------------------------------------------------------------------
SEDS.edsdb = SEDS.load_plugin(edsdb_basename .. ".so");
SEDS.edslib = SEDS.attach_db(SEDS.edsdb[edsdb_load_sym])

-- ------------------------------------------------------------------
-- Step 3: build and load the CFS missionlib runtime library
--
-- Specifically we need the "runtime" code that maps interfaces onto the software bus
-- This code can then be called to get the corresponding msgid values to produce the
-- necessary lookup tables.
--
-- Note that this code uses symbols defined from EDS, so it cannot
-- be built until the headers are generated by previous scripts.
-- ------------------------------------------------------------------
SEDS.execute_tool("BUILD_TOOL", "-j1 missionlib-runtime-install")

local cfe_sb_runtime = SEDS.load_plugin(missionlib_basename .. ".so");

-- ------------------------------------------------------------------
-- Step 4: populate the interface tree using the missionlib functions
-- ------------------------------------------------------------------

-- Helper function to collect the parameters for a given interface
-- It will recursively collect the parameters for all interfaces above it,
-- as these may affect the parameters
local function collect_parameters(instance,requirer)
  local component_impl = instance.component:find_first("IMPLEMENTATION")
  local req_value_set = {}

  instance.params = SEDS.edslib.NewObject(instance.component:get_qualified_name())
  for _,binding in ipairs(instance.provided_links) do
    local intf_params = instance.params[binding.provintf.name]
    local binding_values = collect_parameters(binding.reqinst, binding.reqintf)

    -- find component-specified parameters related to this specific provided intf
    if (component_impl) then
      for pmap in component_impl:iterate_subtree("PARAMETER_MAP") do
        if (pmap.interface == binding.provintf) then
          binding_values[pmap.attributes.parameter] = pmap.attributes.value
        end
      end
    end

    -- match complete set of mappings to the parameters for this interface binding
    for pname,ident in pairs(binding.params) do
      if (not ident.value and binding_values[pname]) then
        ident.method = "eds"
        ident.value = binding_values[pname]
        binding_values[pname] = nil
      end
      if (not ident.value) then
        binding.reqintf:error("parameter undefined", pname)
      elseif (ident.method == "static" or ident.method == "eds") then
        -- Use the supplied value directly
        intf_params[pname] = ident.value
      elseif (ident.method == "cfunction") then
        -- Call the C implementation which should be defined in the runtime
        cfe_sb_runtime[ident.value](intf_params, binding.reqinst.params)
      else
        instance.rule:error("unknown parameter method", ident.method)
      end
    end

    -- Anything unused may be an error in the source datasheet(s)
    for pname,value in pairs(binding_values) do
      instance.component:warning(string.format("Unused Parameter [%s]=%s:%s", tostring(pname), type(value), tostring(value)))
    end
  end

  -- find component-specified parameters related to this specific required intf
  if (component_impl and requirer) then
    for pmap in component_impl:iterate_subtree("PARAMETER_MAP") do
      if (pmap.interface == requirer) then
        req_value_set[pmap.attributes.parameter] = pmap.variableref.attributes.initialvalue
      end
    end
  end

  return req_value_set
end

-- ---------------------------------------------------------
-- MAIN ROUTINE:
-- just call the "collect parameters" for the low level interface
-- all "provided" interfaces will be recursively handled
-- ---------------------------------------------------------
for _,instance in ipairs(SEDS.lowlevel_interfaces) do
  collect_parameters(instance)
end

