-- JJ's Vehicle Mover v0.16.21
-- PERSISTENT F9 AUTO-UNLOAD WATCHER
--
-- Goal:
--   * zero FindAllOf
--   * auto-cache source/destination refs after world load
--   * detect transporter back at its proven home anchors
--   * arm an all-current-cars queue manually with F9
--   * if no safe bay exists, leave all cars on transporter and wait
--   * continue one car at a time only while a safe Automation bay exists
--
-- Proven v0.8.6 movement lifecycle is preserved unchanged.
-- Native Automation race guard uses CurrentTaskTargetZone.
--
-- F6 = lightweight status snapshot only (NO discovery scan)
-- F9 = toggle persistent automatic transporter unload watcher ON/OFF

local OUT_DIR = os.getenv("LOCALAPPDATA") .. "\\JJsVehicleMover"
local LOG_PATH = OUT_DIR .. "\\vehicle_mover_v0.16.21.log"
local UI_STATE_PATH = OUT_DIR .. "\\vehicle_mover_ui_state.json"
local UI_COMMAND_PATH = OUT_DIR .. "\\vehicle_mover_ui_command.txt"

local TOW_CLASS_PATH =
 "/Game/CarDealerSim/Core/Vehicle/NewTowTruck/BP_VehicleTowSlot.BP_VehicleTowSlot_C"

local TRANSPORTER_MANAGER_CLASS_PATH =
 "/Game/CarDealerSim/AI/AITasks/TransporterTask/BP_TransporterVehicleManager.BP_TransporterVehicleManager_C"

local UNDERGROUND_GARAGE_CLASS_PATH =
 "/Game/CarDealerSim/Mechanics/UndergroundGarage/BP_UndergroundGarage.BP_UndergroundGarage_C"

local UNDERGROUND_STORAGE_CLASS_PATH =
 "/Game/CarDealerSim/Mechanics/UndergroundGarage/BPC_UndergroundGarageCarStorage.BPC_UndergroundGarageCarStorage_C"

local UNDERGROUND_ZONE_CLASS_PATH =
 "/Game/CarDealerSim/Mechanics/UndergroundGarage/BP_UndergroundGarageParkingZone.BP_UndergroundGarageParkingZone_C"

math.randomseed(os.time())

local TOW = {
 {1,163021.1155,-82784.8240,541.4689},
 {2,162955.9738,-83340.7300,532.3367},
 {3,163120.8988,-82000.9649,297.5966},
 {4,163029.0010,-82702.3834,234.4117},
 {5,162959.9713,-83292.2403,198.7342},
 {6,163161.0703,-81688.3617,518.0515},
 {7,163093.1079,-82217.9665,511.7069},
}

local AUTO = {
 {1,158713.562743,-87302.363281,118.991765},
 {2,159022.606032,-87346.605869,118.991765},
 {3,159330.326173,-87389.764997,118.991765},
 {4,159645.147828,-87427.718060,118.991765},
 {5,159939.362584,-87465.453982,118.991765},
 {6,160252.858851,-87510.450309,118.991765},
 {7,160561.594719,-87548.724176,118.991765},
 {8,160867.248300,-87588.743790,118.991765},
 {9,161176.939897,-87630.568848,118.991765},
}

local capturedTowRefs = {}
local capturedTowPaths = {}
local towCache = {}
local autoCache = {}
local automationManager = nil
local transporterManager = nil

local notifyRegistered = false
local transporterManagerNotifyRegistered = false
local towReady = false
local autoReady = false
local cacheReady = false
local autoEnabled = false
local tickBusy = false
local moveBusy = false
local homeStableTicks = 0
local lastStateKey = ""
local totalMoved = 0
local worldGeneration = 0
local snapshotNumber = 0
local pendingTransfer = nil
local attach_parent = nil -- forward declaration for native-release handoff watcher
local undergroundGarage = nil
local undergroundPending = nil
local undergroundNotifyRegistered = false
local undergroundStorage = nil
local undergroundStorageNotifyRegistered = false
local integrationTestActive = false
local integrationTransporterDone = false
local integrationUndergroundTarget = 999999 -- continuous master feed; no artificial Underground limit
local integrationUndergroundCompleted = 0
local undergroundNextAllowedAt = 0
local lastUndergroundWaitReason = "" -- native garage reset/cooldown gate between retrievals
local garage_bool = nil -- forward declaration; implementation is defined after the master-feed functions

-- v0.16.0 smart-loop state. Side Parking is automatic Underground intake while F9 is ON.
local undergroundZone=nil
local sideBusy=false
local sideTransferred=0
local sideCurrentCar=nil
local sideCurrentCarId=nil
local sessionJobs={}       -- CarIDs sent to Automation this F9 session (Underground or Transporter)
local sessionProcessed={}  -- jobs already returned through Side -> Underground this session
local completedThisSession=0
local sentToAutomationSession=0
local uiUndergroundStored=0
local uiUndergroundFinished=0
local uiUndergroundNeedsWork=0
local uiLastUndergroundScan=0
local uiLastWrite=0
local lastSideWaitReason=""
local PART_INSTALLED="Installed_1_FE67A71B41D0DCCFF9FF5BA9AB7E9E54"
local PART_DURABILITY="Durability_5_E5CEF82A49BAFF9F95BAEAB8DB143B18"
local READINESS_GROUPS={
 {"Brakes","BrakesParts"},{"Suspension","SuspentionParts"},{"Exhaust","ExhaustParts"},
 {"Clutch","ClutchParts"},{"Engine","EngineParts"},{"Radiator","RadiatorParts"},{"Electrical","ElectricParts"}
}
local SIDE_POINTS={
 {163348.933264,-78964.899952,118.991765},{162849.298796,-78901.252553,118.991765},
 {162347.784714,-78831.530598,118.991765},{161858.238142,-78770.578560,118.991765},
 {161366.079325,-78708.611685,118.991765},{160866.948979,-78636.067566,118.991765},
 {160373.487428,-78572.344780,118.991765}
}
local UG_X,UG_Y,UG_Z=164977.298500,-80832.894440,124.561450
local UG_PITCH,UG_YAW,UG_ROLL=0.224435,-9.554919,0.014569

-- v0.13.5 persistent automatic watcher. F9 toggles the watcher ON/OFF.
-- While ON, each transporter return starts a fresh batch containing however many
-- hauled cars are physically onboard (max 7). Only one native unload may run at
-- a time, and no new unload starts unless at least one safe Automation bay exists.
local batchActive = false
local batchTarget = 0
local batchCompleted = 0
local batchWaitingForBayLogged = false
local batchWaitingForCarLogged = false
local try_start_batch_next = nil

local function mkdir()
 os.execute('if not exist "'..OUT_DIR..'" mkdir "'..OUT_DIR..'"')
end

-- v0.16.21: launch the external WPF overlay from the UE4SS mod lifecycle, not from
-- INSTALL.ps1. This means installing while the game is closed cannot create a UI.
-- The overlay itself is single-instance and exits after the game process disappears.
local function launch_overlay_for_game()
 local pf86=os.getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
 local vbs=pf86.."\\Steam\\steamapps\\common\\Car Dealer Simulator\\CarDealerSimulator\\Binaries\\Win64\\ue4ss\\Mods\\JJsVehicleMover\\LaunchOverlay.vbs"
 local cmd='start "" wscript.exe "'..vbs..'"'
 local ok,ret=pcall(function() return os.execute(cmd) end)
 if not ok then
  local f=io.open(LOG_PATH,"a")
  if f then f:write(os.date("%H:%M:%S").." | Overlay launch failed: "..tostring(ret).."\n"); f:close() end
 end
end

local function log(s)
 local f=io.open(LOG_PATH,"a")
 if f then
  f:write(os.date("%H:%M:%S").." | "..tostring(s).."\n")
  f:close()
 end
end

mkdir()
launch_overlay_for_game()

local function deref(v)
 if v==nil then return nil end
 local out=v
 pcall(function()
  local g=v:get()
  if g~=nil then out=g end
 end)
 return out
end

local function valid(o)
 o=deref(o)
 if o==nil then return false end
 local ok,v=pcall(function() return o:IsValid() end)
 return ok and v==true
end

local function full(o)
 o=deref(o)
 if not valid(o) then return "<invalid>" end
 local ok,s=pcall(function() return o:GetFullName() end)
 return ok and tostring(s) or tostring(o)
end

local function class_name(o)
 o=deref(o)
 if not valid(o) then return "<invalid>" end
 local r="<unknown>"
 pcall(function()
  local c=o:GetClass()
  if c and c:IsValid() then r=c:GetFName():ToString() end
 end)
 return tostring(r)
end

local function location(o)
 o=deref(o)
 if not valid(o) then return nil end
 local ok,p=pcall(function() return o:K2_GetActorLocation() end)
 if not ok or not p then return nil end
 return {x=p.X,y=p.Y,z=p.Z}
end

local function dist(p,x,y,z)
 if not p then return 999999 end
 local dx=p.x-x; local dy=p.y-y; local dz=p.z-z
 return math.sqrt(dx*dx+dy*dy+dz*dz)
end

local function match_anchor(o,list,maxd)
 local p=location(o)
 if not p then return nil,999999 end
 local best=nil
 local bd=999999
 for _,a in ipairs(list) do
  local d=dist(p,a[2],a[3],a[4])
  if d<bd then best=a[1]; bd=d end
 end
 if bd<=maxd then return best,bd end
 return nil,bd
end

local function prop(o,n)
 o=deref(o)
 if not valid(o) then return nil end
 local ok,v=pcall(function() return o[n] end)
 if not ok then return nil end
 return v
end

local function objprop(o,n)
 return deref(prop(o,n))
end

local function boolprop(o,n)
 return prop(o,n)==true
end

local function same_obj(a,b)
 a=deref(a); b=deref(b)
 if not valid(a) or not valid(b) then return false end
 return full(a)==full(b)
end

local function each_array(arr,fn)
 if arr==nil then return false,0 end
 local count=0
 local ok=pcall(function()
  arr:ForEach(function(_,e)
   count=count+1
   fn(deref(e),count)
  end)
 end)
 if ok then return true,count end
 if type(arr)=="table" then
  for _,e in pairs(arr) do
   count=count+1
   fn(deref(e),count)
  end
  return true,count
 end
 return false,count
end

local function reset_world_state(reason)
 worldGeneration=worldGeneration+1
 capturedTowRefs={}
 capturedTowPaths={}
 towCache={}
 autoCache={}
 automationManager=nil
 transporterManager=nil
 towReady=false
 autoReady=false
 cacheReady=false
 homeStableTicks=0
 lastStateKey=""
 moveBusy=false
 pendingTransfer=nil
 undergroundGarage=nil
 undergroundPending=nil
 undergroundStorage=nil
 undergroundZone=nil
 sideBusy=false
 sideCurrentCar=nil
 sideCurrentCarId=nil
 integrationTestActive=false
 integrationTransporterDone=false
 integrationUndergroundCompleted=0
 undergroundNextAllowedAt=0
 batchActive=false
 batchCompleted=0
 batchWaitingForBayLogged=false
 batchWaitingForCarLogged=false
 uiLastUndergroundScan=0
 log("WORLD RESET #"..worldGeneration.." | "..tostring(reason))
end

local function retain_tow(o)
 o=deref(o)
 if not valid(o) then return end
 local path=full(o)
 if capturedTowPaths[path] then return end
 capturedTowPaths[path]=true
 capturedTowRefs[#capturedTowRefs+1]=o
 -- Intentionally no per-object log spam here. This callback must stay cheap.
end


local function retain_transporter_manager(o)
 o=deref(o)
 if not valid(o) then return end
 transporterManager=o
end

local function get_transporter_manager()
 if valid(transporterManager) then return transporterManager end
 -- Exact-class fallback only; never FindAllOf. Normally NotifyOnNewObject supplies this ref.
 local m=nil
 pcall(function() m=FindFirstOf("BP_TransporterVehicleManager_C") end)
 if valid(m) then
  transporterManager=m
  return m
 end
 return nil
end

local function resolve_tow_cache()
 local found={}
 local foundDist={}
 for _,o in ipairs(capturedTowRefs) do
  if valid(o) then
   local slot,d=match_anchor(o,TOW,150.0)
   if slot and (not foundDist[slot] or d<foundDist[slot]) then
    found[slot]=o
    foundDist[slot]=d
   end
  end
 end
 local n=0
 local newCache={}
 for i=1,7 do
  if valid(found[i]) then
   newCache[i]=found[i]
   n=n+1
  end
 end
 if n==7 then towCache=newCache end
 return n
end

local function get_manager()
 if valid(automationManager) then return automationManager end
 local m=nil
 pcall(function() m=FindFirstOf("BP_AutomationRoboticManager_C") end)
 if valid(m) then
  automationManager=m
  return m
 end
 return nil
end

local function resolve_automation_cache_once()
 local m=get_manager()
 if not valid(m) then return 0,0,"manager not found" end
 local za=prop(m,"ZoneActors")
 if za==nil then return 0,0,"ZoneActors unavailable" end

 local found={}
 local foundDist={}
 local ok,count=each_array(za,function(o,_)
  if valid(o) and class_name(o)=="BP_ParkingSlot_Automation_C" then
   local bay,d=match_anchor(o,AUTO,120.0)
   if bay and (not foundDist[bay] or d<foundDist[bay]) then
    found[bay]=o
    foundDist[bay]=d
   end
  end
 end)
 if not ok then return 0,count,"ZoneActors not iterable" end

 local n=0
 local newCache={}
 for i=1,9 do
  if valid(found[i]) then
   newCache[i]=found[i]
   n=n+1
  end
 end
 if n==9 then autoCache=newCache end
 return n,count,nil
end

local function source_vehicle(slotActor)
 if not valid(slotActor) then return nil end
 return objprop(slotActor,"ParkingSlotVehicle")
end

local function bay_block_reason(bay,activeTarget)
 if not valid(bay) then return true,"invalid bay" end
 if valid(activeTarget) and same_obj(bay,activeTarget) then
  return true,"reserved by native Automation"
 end
 if valid(objprop(bay,"ParkingSlotVehicle")) then return true,"registered occupied" end
 if boolprop(bay,"bVehiclesInBounds") then return true,"vehicle in bounds" end
 if boolprop(bay,"ProperlyParked") then return true,"properly parked" end
 return false,"free"
end

local function quat_yaw_deg(q)
 local x=q.X or 0; local y=q.Y or 0; local z=q.Z or 0; local w=q.W or 1
 local siny=2.0*(w*z+x*y)
 local cosy=1.0-2.0*(y*y+z*z)
 return math.deg(math.atan(siny,cosy))
end

local function set_quat_yaw(q,yaw)
 local r=math.rad(yaw)*0.5
 q.X=0.0; q.Y=0.0; q.Z=math.sin(r); q.W=math.cos(r)
end

local function get_transform_for_car(bay)
 local h={}
 local ok,err=pcall(function() bay:GetTransformForCar(h) end)
 if not ok then return nil,nil,nil,"GetTransformForCar failed: "..tostring(err) end
 if h.Rotation==nil or h.Translation==nil then
  return nil,nil,nil,"GetTransformForCar holder missing Rotation/Translation"
 end
 local nativeYaw=quat_yaw_deg(h.Rotation)
 local corrected=nativeYaw-90.0
 set_quat_yaw(h.Rotation,corrected)
 return h,nativeYaw,corrected,nil
end

local function move_one(slotIndex,bayIndex,vehicle,dest)
 local m=get_manager()
 if not valid(m) then return false,"Automation manager invalid" end

 local activeTarget=objprop(m,"CurrentTaskTargetZone")
 local blocked,reason=bay_block_reason(dest,activeTarget)
 if blocked then return false,"destination became blocked: "..reason end

 local sourceSlot=towCache[slotIndex]
 if not valid(sourceSlot) then return false,"source tow slot invalid" end
 local registered=source_vehicle(sourceSlot)
 if not valid(registered) or not same_obj(registered,vehicle) then
  return false,"source slot no longer owns expected vehicle"
 end
 if not boolprop(vehicle,"IsHauled") and not boolprop(vehicle,"isHauled") then
  return false,"vehicle is not hauled"
 end

 local tr,nativeYaw,corrected,terr=get_transform_for_car(dest)
 if not tr then return false,terr end

 -- v0.12.2 TEST: mirror the native unload state we observed before moving to Automation.
 -- Native UI unload position observed repeatedly behind transporter:
 --   (162828.2, -84194.6, ~229.7), yaw -97.205
 -- We do NOT call RemoveVehicleFromTransport (previous delayed-crash risk).
 local unloadTr={}
 unloadTr.Translation={X=162828.2,Y=-84194.6,Z=229.7}
 unloadTr.Rotation={X=0.0,Y=0.0,Z=-0.750111,W=0.661312} -- approx yaw -97.205
 unloadTr.Scale3D={X=1.0,Y=1.0,Z=1.0}

 local ok1=pcall(function() vehicle.IsHauled=false end)
 local ok2=pcall(function() vehicle.isHauled=false end)
 if not ok1 and not ok2 then return false,"failed to clear hauled state" end

 local ok3,e3=pcall(function() sourceSlot:SetParkingSlotVehicle(nil,false) end)
 if not ok3 then return false,"clear source failed: "..tostring(e3) end
 local okp,ep=pcall(function() sourceSlot.ProperlyParked=false end)
 if not okp then return false,"clear ProperlyParked failed: "..tostring(ep) end

 local ok4,e4=pcall(function() vehicle:K2_DetachFromActor(1,1,1) end)
 if not ok4 then return false,"detach failed: "..tostring(e4) end

 local hit={}
 local oku,eu=pcall(function() vehicle:K2_SetActorTransform(unloadTr,false,hit,true) end)
 if not oku then return false,"native-unload-position move failed: "..tostring(eu) end

 log(string.format("STAGE 1 NATIVE-UNLOAD MIRROR | Slot %d | sourceEmpty=%s ProperlyParked=%s | behind transporter",
  slotIndex,tostring(not valid(source_vehicle(sourceSlot))),tostring(boolprop(sourceSlot,"ProperlyParked"))))

 -- Keep this deliberately in one game-thread operation: the important test is that the
 -- transporter source is first put into the same visible released state as native UI unload.
 local hit2={}
 local ok5,e5=pcall(function() vehicle:K2_SetActorTransform(tr,false,hit2,true) end)
 if not ok5 then return false,"Automation SetActorTransform failed: "..tostring(e5) end
 local ok6,e6=pcall(function() dest:SetOverlappingVehicle(vehicle) end)
 if not ok6 then return false,"SetOverlappingVehicle failed: "..tostring(e6) end
 local ok7,e7=pcall(function() dest:SetParkingSlotVehicle(vehicle,true) end)
 if not ok7 then return false,"SetParkingSlotVehicle failed: "..tostring(e7) end

 local sourceEmpty=not valid(source_vehicle(sourceSlot))
 local sourceReleased=not boolprop(sourceSlot,"ProperlyParked")
 local destOwns=same_obj(objprop(dest,"ParkingSlotVehicle"),vehicle)
 local p=location(vehicle)
 local a=AUTO[bayIndex]
 local d=dist(p,a[2],a[3],a[4])
 local hauled=boolprop(vehicle,"IsHauled") or boolprop(vehicle,"isHauled")
 log(string.format(
  "STAGE 2 AUTOMATION | Slot %d -> Bay %d | sourceEmpty=%s sourceProperlyParked=%s destOwns=%s dist=%.1fcm IsHauled=%s",
  slotIndex,bayIndex,tostring(sourceEmpty),tostring(boolprop(sourceSlot,"ProperlyParked")),tostring(destOwns),d,tostring(hauled)))
 return sourceEmpty and sourceReleased and destOwns and d<5.0 and not hauled,nil
end

local function move_released_to_automation(p)
 if p==nil or not valid(p.vehicle) then return false,"pending vehicle invalid" end
 if not valid(p.sourceSlot) then return false,"pending source slot invalid" end

 -- The native BeginCarUnloadSequence must have fully released this exact car first.
 if valid(source_vehicle(p.sourceSlot)) then return false,"native unload still owns source slot" end
 if boolprop(p.vehicle,"IsHauled") or boolprop(p.vehicle,"isHauled") then
  return false,"native unload has not cleared hauled state yet"
 end
 if valid(attach_parent(p.vehicle)) then return false,"native unload has not detached vehicle yet" end

 local m=get_manager()
 if not valid(m) then return false,"Automation manager invalid" end
 local activeTarget=objprop(m,"CurrentTaskTargetZone")

 local freeBay=nil
 local freeCount=0
 for i=1,9 do
  local blocked=bay_block_reason(autoCache[i],activeTarget)
  if not blocked then
   freeCount=freeCount+1
   if not freeBay then freeBay=i end
  end
 end
 if not freeBay then return false,"no safe Automation bay available" end

 local dest=autoCache[freeBay]
 local tr,nativeYaw,corrected,terr=get_transform_for_car(dest)
 if not tr then return false,terr end

 log("NATIVE RELEASE CONFIRMED | Slot "..p.slotIndex.." | car="..full(p.vehicle)..
     " | choosing Automation Bay "..freeBay.." | safe bays="..freeCount)

 local hit={}
 local ok1,e1=pcall(function() p.vehicle:K2_SetActorTransform(tr,false,hit,true) end)
 if not ok1 then return false,"Automation SetActorTransform failed: "..tostring(e1) end
 local ok2,e2=pcall(function() dest:SetOverlappingVehicle(p.vehicle) end)
 if not ok2 then return false,"SetOverlappingVehicle failed: "..tostring(e2) end
 local ok3,e3=pcall(function() dest:SetParkingSlotVehicle(p.vehicle,true) end)
 if not ok3 then return false,"SetParkingSlotVehicle failed: "..tostring(e3) end

 local destOwns=same_obj(objprop(dest,"ParkingSlotVehicle"),p.vehicle)
 local pos=location(p.vehicle)
 local a=AUTO[freeBay]
 local d=dist(pos,a[2],a[3],a[4])
 local hauled=boolprop(p.vehicle,"IsHauled") or boolprop(p.vehicle,"isHauled")
 local properly=boolprop(dest,"ProperlyParked")
 local inBounds=boolprop(dest,"bVehiclesInBounds")
 log(string.format(
  "AUTOMATION HANDOFF RESULT | Bay %d | destOwns=%s | dist=%.1fcm | IsHauled=%s | ProperlyParked=%s | bVehiclesInBounds=%s",
  freeBay,tostring(destOwns),d,tostring(hauled),tostring(properly),tostring(inBounds)))

 return destOwns and d<5.0 and not hauled,nil
end

local car_id
local normalize_car_id_text

local function pending_transfer_tick()
 if pendingTransfer==nil then return end
 local p=pendingTransfer
 if p.worldGeneration~=worldGeneration then
  log("PENDING TRANSFER CANCELLED: world changed")
  pendingTransfer=nil; moveBusy=false
  return
 end

 p.checks=(p.checks or 0)+1
 local sourceEmpty=not valid(source_vehicle(p.sourceSlot))
 local hauled=boolprop(p.vehicle,"IsHauled") or boolprop(p.vehicle,"isHauled")
 local attached=valid(attach_parent(p.vehicle))
 if not sourceEmpty or hauled or attached then
  if p.checks<=10 then
   log("WAITING FOR NATIVE RELEASE | check="..p.checks.." | sourceEmpty="..tostring(sourceEmpty)..
       " | hauled="..tostring(hauled).." | attached="..tostring(attached))
   return
  end
  log("TRANSFER ABORTED: native release did not complete within 10 checks")
  pendingTransfer=nil; moveBusy=false
  return
 end

 local ok,err=move_released_to_automation(p)
 if ok then
  totalMoved=totalMoved+1
  sentToAutomationSession=sentToAutomationSession+1
  local movedId=car_id(p.vehicle)
  if movedId and movedId~="<none>" and movedId~="<unavailable>" then sessionJobs[movedId]=true end
  if batchActive then batchCompleted=batchCompleted+1 end
  if batchActive then
   log("ONE-CAR NATIVE UNLOAD -> AUTOMATION SUCCESS | batch="..tostring(batchCompleted).."/"..tostring(batchTarget).." | total moved this session="..totalMoved)
  else
   log("ONE-CAR NATIVE UNLOAD -> AUTOMATION SUCCESS | automatic watcher OFF; in-flight car completed safely | total moved this session="..totalMoved)
  end
  pendingTransfer=nil; moveBusy=false
  batchWaitingForBayLogged=false
  batchWaitingForCarLogged=false
  if batchActive and batchCompleted>=batchTarget then
   log("AUTO BATCH COMPLETE | "..batchCompleted.."/"..batchTarget.." cars transferred | watcher remains "..(autoEnabled and "ON" or "OFF"))
   batchActive=false
   if integrationTestActive then
    integrationTransporterDone=true
    log("INTEGRATION PHASE 1 COMPLETE | transporter is now clear; Underground phase may begin")
   end
  end
 else
  if tostring(err)=="no safe Automation bay available" then
   log("NATIVE CAR RELEASED | waiting for a safe Automation bay")
   return
  end
  log("AUTOMATION HANDOFF ABORTED: "..tostring(err))
  pendingTransfer=nil; moveBusy=false
 end
end

local function retain_underground_garage(o)
 o=deref(o)
 if not valid(o) then return end
 undergroundGarage=o
 log("UNDERGROUND GARAGE captured | "..full(o))
end

local function retain_underground_storage(o)
 o=deref(o)
 if not valid(o) then return end
 undergroundStorage=o
 log("UNDERGROUND STORAGE captured | "..full(o))
end

local function unwrap_ue_string(v)
 if v==nil then return "" end
 local tv=type(v)
 if tv=="string" or tv=="number" or tv=="boolean" then return tostring(v) end
 local attempts={
  function() return v:ToString() end,
  function() return v:GetString() end,
  function() return v:String() end,
  function() return v.Text end,
  function() return v.Value end,
  function() return v.String end,
  function() return v.Data end
 }
 for _,fn in ipairs(attempts) do
  local ok,res=pcall(fn)
  if ok and res~=nil then
   local t=tostring(res)
   if t~="" and t~="nil" and not t:find("TrivialObject",1,true) then return t end
  end
 end
 return ""
end

local function direct_struct_field(o,n)
 if o==nil then return nil end
 local v=nil; pcall(function() v=o[n] end); return v
end
local function count_array_items(arr)
 if arr==nil then return 0 end
 local n=0; pcall(function() arr:ForEach(function(_,_) n=n+1 end) end); return n
end
local function score_part_group(obj,propName)
 local group=prop(obj,propName); if group==nil then return nil end
 local total,count=0,0
 local ok=pcall(function()
  group:ForEach(function(_,b)
   local state=b; pcall(function() local g=b:get(); if g~=nil then state=g end end)
   if state~=nil then
    count=count+1
    local installed=direct_struct_field(state,PART_INSTALLED)
    local durability=tonumber(unwrap_ue_string(direct_struct_field(state,PART_DURABILITY)))
    if installed==true or installed==1 then total=total+(durability or 0) end
   end
  end)
 end)
 if not ok or count<=0 then return nil end
 return total/count
end
local function count_exhaust_holes(obj)
 local group=prop(obj,"ExhaustHoles"); if group==nil then return nil end
 local n=0; local ok=pcall(function() group:ForEach(function(_,_) n=n+1 end) end)
 if not ok then return nil end
 return n
end
local function stored_readiness(obj)
 local sum,count=0,0
 for _,g in ipairs(READINESS_GROUPS) do
  local v=score_part_group(obj,g[2]); if v~=nil then sum=sum+v; count=count+1 end
 end
 local holes=count_exhaust_holes(obj)
 if holes~=nil then sum=sum+((holes==0) and 1.0 or 0.0); count=count+1 end
 local condition=(count>0) and (sum/count) or nil
 local photos=count_array_items(prop(obj,"CapturedPoints"))
 local photosMax=tonumber(unwrap_ue_string(prop(obj,"CapturedPointsMax"))) or 7
 local boothRaw=prop(obj,"PhotoMadeByPhotoStudio")
 local booth=(boothRaw==true or boothRaw==1)
 local finished=(condition~=nil and condition>=0.95 and photosMax>0 and photos>=photosMax and booth)
 return finished,condition,photos,photosMax,booth
end

-- One-shot storage read only. Never called while the native garage sequence is active.
-- v0.16.0: only NEEDS WORK cars are eligible; FINISHED and already-processed session jobs are skipped.
local function choose_random_underground_carid()
 local storage=deref(undergroundStorage)
 if not valid(storage) then return nil,0,"Underground storage not captured" end
 local stored=prop(storage,"StoredCars")
 if stored==nil then return nil,0,"StoredCars unavailable" end
 local ids,seen={},{}
 local total,finishedCount,processedCount,unavailable=0,0,0,0
 local ok,err=pcall(function()
  stored:ForEach(function(key,value)
   total=total+1
   local id=unwrap_ue_string(key)
   local obj=value; pcall(function() local got=value:get(); if got~=nil then obj=got end end); obj=deref(obj)
   local valueId=""
   if valid(obj) then valueId=unwrap_ue_string(prop(obj,"CarID")); if valueId=="" then valueId=unwrap_ue_string(prop(obj,"CarId")) end end
   if id=="" then id=valueId end
   if id~="" and id~="nil" and not id:find("function:",1,true) and not id:find("TrivialObject",1,true) and not seen[id] then
    seen[id]=true
    if sessionProcessed[id] then
     processedCount=processedCount+1
    elseif valid(obj) then
     local finished,condition,photos,photosMax,booth=stored_readiness(obj)
     if condition==nil then
      unavailable=unavailable+1
     elseif finished then
      finishedCount=finishedCount+1
     else
      ids[#ids+1]=id
     end
    else
     unavailable=unavailable+1
    end
   end
  end)
 end)
 if not ok then return nil,0,"StoredCars readiness read failed: "..tostring(err) end
 if #ids==0 then
  return nil,0,string.format("no NEEDS WORK Underground candidates | stored=%d finished=%d processedThisSession=%d unavailable=%d",total,finishedCount,processedCount,unavailable)
 end
 table.sort(ids)
 return ids[math.random(1,#ids)],#ids,string.format("stored=%d finishedSkipped=%d processedSkipped=%d unavailable=%d",total,finishedCount,processedCount,unavailable)
end

local function get_underground_parked_vehicle()
 local g=deref(undergroundGarage)
 if not valid(g) then return nil,"garage invalid" end
 local out={}
 local ok,err=pcall(function() g:GetParkedVehicle(out) end)
 if not ok then return nil,"GetParkedVehicle failed: "..tostring(err) end
 for _,v in pairs(out) do
  v=deref(v)
  if valid(v) then return v,nil end
 end
 return nil,nil
end

local function first_free_automation_bay()
 local m=get_manager()
 if not valid(m) then return nil,0,"Automation manager invalid" end
 local activeTarget=objprop(m,"CurrentTaskTargetZone")
 local first=nil; local count=0
 for i=1,9 do
  local blocked=bay_block_reason(autoCache[i],activeTarget)
  if not blocked then count=count+1; if not first then first=i end end
 end
 return first,count,nil
end

local function move_underground_vehicle_to_automation(vehicle,bayIndex)
 vehicle=deref(vehicle)
 if not valid(vehicle) then return false,"retrieved vehicle invalid" end
 local m=get_manager()
 if not valid(m) then return false,"Automation manager invalid" end
 local dest=autoCache[bayIndex]
 local activeTarget=objprop(m,"CurrentTaskTargetZone")
 local blocked,reason=bay_block_reason(dest,activeTarget)
 if blocked then return false,"reserved bay became blocked: "..tostring(reason) end
 local tr,_,_,terr=get_transform_for_car(dest)
 if not tr then return false,terr end
 local hit={}
 local ok1,e1=pcall(function() vehicle:K2_SetActorTransform(tr,false,hit,true) end)
 if not ok1 then return false,"Automation SetActorTransform failed: "..tostring(e1) end
 local ok2,e2=pcall(function() dest:SetOverlappingVehicle(vehicle) end)
 if not ok2 then return false,"SetOverlappingVehicle failed: "..tostring(e2) end
 local ok3,e3=pcall(function() dest:SetParkingSlotVehicle(vehicle,true) end)
 if not ok3 then return false,"SetParkingSlotVehicle failed: "..tostring(e3) end
 local owns=same_obj(objprop(dest,"ParkingSlotVehicle"),vehicle)
 local pos=location(vehicle); local a=AUTO[bayIndex]; local d=dist(pos,a[2],a[3],a[4])
 log(string.format("UNDERGROUND -> AUTOMATION RESULT | Bay %d | destOwns=%s | dist=%.1fcm | car=%s",bayIndex,tostring(owns),d,full(vehicle)))
 return owns and d<5.0,nil
end

local function underground_transfer_tick()
 local p=undergroundPending
 if p==nil then return end
 if p.worldGeneration~=worldGeneration then log("UNDERGROUND TEST CANCELLED: world changed"); undergroundPending=nil; return end
 p.checks=(p.checks or 0)+1
 local car,err=get_underground_parked_vehicle()
 if err then log("UNDERGROUND TEST ABORTED: "..err); undergroundPending=nil; return end
 if valid(car) then
  local seenId=car_id(car)
  local wantedId=normalize_car_id_text(p.carId)
  if wantedId=="" then wantedId=tostring(p.carId or "") end
  if seenId~=nil then seenId=tostring(seenId) end
  if seenId~=wantedId then
   log("UNDERGROUND STALE/WRONG CAR IGNORED | requested CarID="..wantedId.." | seen CarID="..tostring(seenId).." | car="..full(car))
  elseif not valid(p.vehicle) then
   p.vehicle=car; p.firstSeen=os.time(); p.stable=0
   log("UNDERGROUND EXACT CARID MATCH | requested CarID="..wantedId.." | car="..full(car).." | waiting for native garage sequence to finish")
  elseif same_obj(p.vehicle,car) then
   local parent=attach_parent(car)
   if not valid(parent) then p.stable=p.stable+1 else p.stable=0 end
  end
 end
 -- v0.15.1 timing tune #2: keep a visible pause after the native car arrives, but
 -- hand off after one detached 2-second check.
 -- This preserves a real native-release stability gate without making the car linger.
 if valid(p.vehicle) and (p.stable or 0)>=1 then
  local blocked,reason=bay_block_reason(autoCache[p.bay],objprop(get_manager(),"CurrentTaskTargetZone"))
  if blocked then log("UNDERGROUND TEST WAITING: reserved Automation Bay "..p.bay.." became blocked: "..tostring(reason)); return end
  log("UNDERGROUND NATIVE RELEASE WAIT PASSED | moving retrieved car to reserved Automation Bay "..p.bay)
  local ok,merr=move_underground_vehicle_to_automation(p.vehicle,p.bay)
  if ok then
   log("UNDERGROUND -> AUTOMATION SUCCESS | CarID="..p.carId.." | Bay="..p.bay)
   sentToAutomationSession=sentToAutomationSession+1
   sessionJobs[p.carId]=true
   if p.integration and autoEnabled then
    integrationUndergroundCompleted=integrationUndergroundCompleted+1
    undergroundNextAllowedAt=os.time()+5
    log("MASTER FEED PROGRESS | Underground cars moved this run="..integrationUndergroundCompleted)
    log("UNDERGROUND NATIVE RESET COOLDOWN | minimum 5 seconds + verified garage-idle gate before next retrieval")
   end
  else
   log("UNDERGROUND -> AUTOMATION FAILED: "..tostring(merr))
   if p.integration then integrationTestActive=false end
  end
  undergroundPending=nil
 elseif p.checks<=15 then
  log("UNDERGROUND WAIT | check="..p.checks.." | carSeen="..tostring(valid(p.vehicle)).." | detachedStable="..tostring(p.stable or 0).." | elapsed="..tostring(os.time()-p.started).."s")
 end
 if (os.time()-p.started)>90 then
  log("UNDERGROUND TEST ABORTED: native retrieval did not become ready within 90 seconds | CONTROLLED TEST STOPPED - no automatic retry")
  undergroundPending=nil
  if p.integration then integrationTestActive=false; autoEnabled=false end
 end
end

local function start_next_random_underground()
 if undergroundPending~=nil then return false,"Underground transfer already active" end
 if not cacheReady then return false,"cache not ready" end
 if moveBusy or pendingTransfer~=nil or batchActive then return false,"transporter mover busy" end
 local g=deref(undergroundGarage)
 if not valid(g) then return false,"Underground Garage not captured" end
 -- v0.16.21: never start a second native retrieval until the Underground Garage
 -- has fully returned to idle. The old 3-second time-only cooldown could expire
 -- while the previous native garage sequence was still clearing, leaving the next
 -- retrieved car stranded/sideways at the garage exit.
 local blocked=garage_bool("IsZoneBlocked")
 local proper=garage_bool("HasProperlyParkedVehicle")
 local parked=get_underground_parked_vehicle()
 if blocked==true or proper==true or valid(parked) then
  return false,"Underground Garage native sequence still busy/resetting"
 end
 local bay,count,berr=first_free_automation_bay()
 if not bay then return false,"no safe Automation bay available | "..tostring(berr or "free=0") end
 local carId,storedCount,cerr=choose_random_underground_carid()
 if not carId then return false,cerr end
 log("============================================================")
 log("MASTER FEED UNDERGROUND NEXT | NEEDS WORK CarID="..carId.." | eligible candidates="..storedCount.." | "..tostring(cerr or "").." | reserved Bay="..bay)
 log("Calling native BP_UndergroundGarage_C:RemoveVehicleFromGarage(CarID); StoredCars was read ONCE while garage idle")
 local ok,callerr=pcall(function() g:RemoveVehicleFromGarage(carId) end)
 if not ok then log("UNDERGROUND NATIVE CALL FAILED: "..tostring(callerr)); log("============================================================"); return false,tostring(callerr) end
 undergroundPending={worldGeneration=worldGeneration,carId=carId,bay=bay,started=os.time(),checks=0,stable=0,vehicle=nil,integration=true}
 log("NATIVE UNDERGROUND RETRIEVAL STARTED | waiting conservatively before Automation handoff")
 log("============================================================")
 return true,nil
end

local function transporter_is_home()
 if not towReady then return false end
 for i=1,7 do
  if not valid(towCache[i]) then return false end
  local p=location(towCache[i])
  local a=TOW[i]
  if dist(p,a[2],a[3],a[4])>175.0 then return false end
 end
 return true
end

local function cache_tick()
 if cacheReady then return end

 if not towReady then
  local n=resolve_tow_cache()
  if n==7 then
   towReady=true
   log("AUTO CACHE: transporter resolved 7/7 from NotifyOnNewObject refs")
  end
  return -- stagger cache work; Automation cache happens on a later cycle.
 end

 if not autoReady then
  local n,count,err=resolve_automation_cache_once()
  if n==9 then
   autoReady=true
   log("AUTO CACHE: Automation resolved 9/9 from manager.ZoneActors (count="..count..")")
  elseif err then
   -- Only log occasionally via state key, not every loop.
   local key="CACHE_WAIT|"..tostring(n).."|"..tostring(err)
   if key~=lastStateKey then
    lastStateKey=key
    log("AUTO CACHE waiting: "..tostring(err).." | bays="..n.."/9")
   end
  end
  return
 end

 cacheReady=true
 lastStateKey=""
 log("CACHE READY=true | AUTO WATCHER="..(autoEnabled and "ON" or "OFF").." | F9 toggles ON/OFF")
end

local function current_counts(activeTarget)
 local sourceCount=0
 local freeCount=0
 for i=1,7 do
  if valid(source_vehicle(towCache[i])) then sourceCount=sourceCount+1 end
 end
 for i=1,9 do
  local blocked=bay_block_reason(autoCache[i],activeTarget)
  if not blocked then freeCount=freeCount+1 end
 end
 return sourceCount,freeCount
end


-- v0.16.12 compact UI bridge. This deliberately uses only cached objects and tiny
-- diagnostic files. Underground readiness is refreshed at most every 15 seconds,
-- and never while a native Underground IN/OUT sequence is active.
local function json_escape(v)
 local t=tostring(v or "")
 t=t:gsub("\\","\\\\"):gsub('"','\\"'):gsub("\r"," "):gsub("\n"," ")
 return t
end

local function ui_scan_underground_if_safe()
 local now=os.time()
 if (now-(uiLastUndergroundScan or 0))<15 then return end
 if undergroundPending~=nil or sideBusy then return end
 local storage=deref(undergroundStorage)
 if not valid(storage) then return end
 local stored=prop(storage,"StoredCars")
 if stored==nil then return end
 local total,finished,needs=0,0,0
 local ok=pcall(function()
  stored:ForEach(function(_,value)
   total=total+1
   local obj=value; pcall(function() local got=value:get(); if got~=nil then obj=got end end); obj=deref(obj)
   if valid(obj) then
    local isFinished,condition=stored_readiness(obj)
    if condition~=nil and isFinished then finished=finished+1 else needs=needs+1 end
   else
    needs=needs+1
   end
  end)
 end)
 if ok then
  uiUndergroundStored=total; uiUndergroundFinished=finished; uiUndergroundNeedsWork=needs
  uiLastUndergroundScan=now
 end
end

local function ui_activity_text(sourceCount,freeCount)
 if not cacheReady then return "Waiting for game cache..." end
 if pendingTransfer~=nil then return "Transporter -> Automation" end
 if undergroundPending~=nil then return "Underground -> Automation" end
 if sideBusy then return "Side Parking -> Underground" end
 if batchActive then return "Feeding Transporter cars to Automation" end
 if autoEnabled then
  if freeCount<=0 then return "Waiting - Automation bays full" end
  if sourceCount>0 then return "Transporter ready - selecting next car" end
  return "Watching Transporter, Side Parking and Underground"
 end
 return "Mover is OFF"
end

local function ui_write_state()
 local now=os.time()
 if (now-(uiLastWrite or 0))<2 then return end
 uiLastWrite=now
 ui_scan_underground_if_safe()
 local sourceCount,freeCount=0,0
 if cacheReady then
  local m=get_manager(); local active=nil
  if valid(m) then active=objprop(m,"CurrentTaskTargetZone") end
  sourceCount,freeCount=current_counts(active)
 end
 local used=cacheReady and (9-freeCount) or 0
 if used<0 then used=0 elseif used>9 then used=9 end
 local status=ui_activity_text(sourceCount,freeCount)
 local f=io.open(UI_STATE_PATH,"w")
 if f then
  f:write('{')
  f:write('"enabled":'..tostring(autoEnabled)..',')
  f:write('"cacheReady":'..tostring(cacheReady)..',')
  f:write('"automationUsed":'..tostring(used)..',')
  f:write('"transporterCars":'..tostring(sourceCount)..',')
  f:write('"undergroundStored":'..tostring(uiUndergroundStored)..',')
  f:write('"undergroundFinished":'..tostring(uiUndergroundFinished)..',')
  f:write('"undergroundNeedsWork":'..tostring(uiUndergroundNeedsWork)..',')
  f:write('"completedThisSession":'..tostring(completedThisSession)..',')
  f:write('"sentToAutomation":'..tostring(sentToAutomationSession)..',')
  f:write('"sideStoredThisSession":'..tostring(sideTransferred)..',')
  f:write('"status":"'..json_escape(status)..'",')
  f:write('"updated":"'..json_escape(os.date("%H:%M:%S"))..'"}')
  f:close()
 end
end

local toggle_master_feed -- shared by F9 and compact UI button
local function ui_poll_command()
 local f=io.open(UI_COMMAND_PATH,"r")
 if not f then return end
 local cmd=f:read("*a") or ""; f:close(); os.remove(UI_COMMAND_PATH)
 cmd=cmd:gsub("%s+",""):upper()
 if cmd=="TOGGLE" and toggle_master_feed then toggle_master_feed("UI") end
end

-- Legacy single-move automatic path removed in v0.13.5.
-- Persistent F9 watcher below is the only automatic mover path.

local function scalar_text(v)
 if v==nil then return "<nil>" end
 if type(v)=="boolean" or type(v)=="number" or type(v)=="string" then return tostring(v) end
 local o=deref(v)
 if valid(o) then return full(o) end
 local ok,t=pcall(function() return tostring(v) end)
 return ok and t or "<unreadable>"
end

local function property_text(o,name)
 local v=prop(o,name)
 if v==nil then return "<nil/unavailable>" end
 local d=deref(v)
 if valid(d) then return full(d) end
 return scalar_text(v)
end

local function actor_owner(o)
 local r=nil
 pcall(function() r=o:GetOwner() end)
 return deref(r)
end

attach_parent = function(o)
 local r=nil
 pcall(function() r=o:GetAttachParentActor() end)
 return deref(r)
end

local function unwrap_ue_string(v)
 if v==nil then return "" end
 local tv=type(v)
 if tv=="string" or tv=="number" or tv=="boolean" then return tostring(v) end
 local attempts={
  function() return v:ToString() end,
  function() return v:GetString() end,
  function() return v:String() end,
  function() return v.Text end,
  function() return v.Value end,
  function() return v.String end,
  function() return v.Data end
 }
 for _,fn in ipairs(attempts) do
  local ok,res=pcall(fn)
  if ok and res~=nil then
   local s=tostring(res)
   if s~="" and s~="nil" and
      not s:find("TrivialObject",1,true) and
      not s:find("FString:",1,true) and
      not s:find("UObject:",1,true) then
    return s
   end
  end
 end
 return ""
end

normalize_car_id_text = function(v)
 local s=unwrap_ue_string(v)
 if s=="" then return "" end
 s=s:gsub("^%s+",""):gsub("%s+$","")
 local hex=s:match("^([0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f])$")
 if hex then return string.upper(hex) end
 -- Preserve known non-GUID IDs such as CAR1 for bookkeeping, but never
 -- mistake a UE4SS wrapper/address rendering for a saved CarID.
 if not s:find(":",1,true) and not s:find(" ",1,true) then return s end
 return ""
end

car_id = function(v)
 v=deref(v)
 if not valid(v) then return "<none>" end
 local info=objprop(v,"VehicleInfoObject")
 if valid(info) then
  local id=normalize_car_id_text(prop(info,"CarID"))
  if id~="" then return id end
 end
 local id=normalize_car_id_text(prop(v,"CarID"))
 if id~="" then return id end
 return "<unavailable>"
end

local function log_object_array(owner,name)
 local arr=prop(owner,name)
 if arr==nil then
  log("MANAGER "..name.." = <nil/unavailable>")
  return
 end
 local entries={}
 local ok,count=each_array(arr,function(e,i)
  if valid(e) then
   entries[#entries+1]=string.format("[%d] %s | CarID=%s",i,full(e),car_id(e))
  else
   entries[#entries+1]=string.format("[%d] %s",i,scalar_text(e))
  end
 end)
 log("MANAGER "..name.." iterable="..tostring(ok).." | count="..tostring(count))
 for _,line in ipairs(entries) do log("  "..line) end
end

local function deep_status_snapshot()
 snapshotNumber=snapshotNumber+1
 log("============================================================")
 log("F6 DEEP TRANSPORTER SNAPSHOT #"..snapshotNumber)
 log("Notify refs="..#capturedTowRefs..
     " | towReady="..tostring(towReady)..
     " | autoReady="..tostring(autoReady)..
     " | cacheReady="..tostring(cacheReady)..
     " | autoEnabled="..tostring(autoEnabled)..
     " | totalMoved="..totalMoved..
     " | batchActive="..tostring(batchActive)..
     " | batch="..tostring(batchCompleted).."/"..tostring(batchTarget)..
     " | realTransporterManager="..tostring(valid(get_transporter_manager())))

 if not towReady then
  log("Tow cache not ready yet - wait a few seconds and press F6 again")
  log("============================================================")
  return
 end

 log("Transporter home="..tostring(transporter_is_home()))

 for i=1,7 do
  local slot=towCache[i]
  log("------------------------------------------------------------")
  log("SLOT "..i.." | actor="..full(slot))
  if valid(slot) then
   local p=location(slot)
   if p then log(string.format("SLOT %d location=(%.1f, %.1f, %.1f)",i,p.x,p.y,p.z)) end

   local pv=objprop(slot,"ParkingSlotVehicle")
   local ov=objprop(slot,"VehicleOverlapping")
   local dv=objprop(slot,"DetectedVehicle")
   local only=objprop(slot,"OnlyVehicleOverlapping")

   log("SLOT "..i.." ParkingSlotVehicle="..(valid(pv) and full(pv) or "<empty/invalid>"))
   log("SLOT "..i.." VehicleOverlapping="..(valid(ov) and full(ov) or "<empty/invalid>"))
   log("SLOT "..i.." DetectedVehicle="..(valid(dv) and full(dv) or "<empty/invalid>"))
   log("SLOT "..i.." OnlyVehicleOverlapping="..scalar_text(prop(slot,"OnlyVehicleOverlapping")))
   log("SLOT "..i.." ProperlyParked="..scalar_text(prop(slot,"ProperlyParked"))..
       " | bVehiclesInBounds="..scalar_text(prop(slot,"bVehiclesInBounds")))
   log("SLOT "..i.." ParkingID="..scalar_text(prop(slot,"ParkingID"))..
       " | ZoneType="..scalar_text(prop(slot,"ZoneType")))
   local own=actor_owner(slot)
   local par=attach_parent(slot)
   log("SLOT "..i.." Owner="..(valid(own) and full(own) or "<none>"))
   log("SLOT "..i.." AttachParent="..(valid(par) and full(par) or "<none>"))

   if valid(pv) then
    local vp=location(pv)
    log("  VEHICLE CarID="..car_id(pv)..
        " | IsHauled="..scalar_text(prop(pv,"IsHauled"))..
        " | isHauled="..scalar_text(prop(pv,"isHauled"))..
        " | IsReservedByNPCTransporter="..scalar_text(prop(pv,"IsReservedByNPCTransporter"))..
        " | isReservedByNPCTransporter="..scalar_text(prop(pv,"isReservedByNPCTransporter"))..
        " | bIsReservedByEmployer="..scalar_text(prop(pv,"bIsReservedByEmployer")))
    if vp then log(string.format("  VEHICLE location=(%.1f, %.1f, %.1f)",vp.x,vp.y,vp.z)) end
    local vown=actor_owner(pv)
    local vpar=attach_parent(pv)
    log("  VEHICLE Owner="..(valid(vown) and full(vown) or "<none>"))
    log("  VEHICLE AttachParent="..(valid(vpar) and full(vpar) or "<none>"))
   end
  end
 end

 local tm=get_transporter_manager()
 log("------------------------------------------------------------")
 if valid(tm) then
  log("REAL TRANSPORTER MANAGER="..full(tm))
  log("TRANSPORTER MANAGER CLASS="..class_name(tm))
  log("MANAGER Parking="..property_text(tm,"Parking"))
  log("MANAGER CanAbortCurrentTransport="..property_text(tm,"CanAbortCurrentTransport"))
  log("MANAGER TransporterLeaveTimeLimitCheck="..property_text(tm,"TransporterLeaveTimeLimitCheck"))
  log("MANAGER TransporterLeaveTimeout="..property_text(tm,"TransporterLeaveTimeout"))
  log_object_array(tm,"VehiclesToTransport")
  log_object_array(tm,"VehiclesID")
 else
  log("REAL TRANSPORTER MANAGER=<invalid/not found>")
 end

 if cacheReady then
  local activeTarget=nil
  local am=get_manager()
  if valid(am) then activeTarget=objprop(am,"CurrentTaskTargetZone") end
  local sources,free=current_counts(activeTarget)
  log("SUMMARY onboard registered="..sources.." | safe Automation bays="..free)
 end
 log("F6 DEEP SNAPSHOT COMPLETE #"..snapshotNumber)
 log("============================================================")
end

local function native_begin_unload_one(triggerLabel)
 if moveBusy or pendingTransfer~=nil then
  log(tostring(triggerLabel or "BATCH").." ignored: one-car transfer already busy")
  return false
 end
 if not cacheReady or not towReady or not autoReady then
  log(tostring(triggerLabel or "BATCH").." ABORT: cache not ready")
  return false
 end
 if not transporter_is_home() then
  log(tostring(triggerLabel or "BATCH").." ABORT: transporter is not at proven home anchors")
  return false
 end

 local m=get_manager()
 if not valid(m) then log(tostring(triggerLabel or "BATCH").." ABORT: Automation manager invalid") return false end
 local activeTarget=objprop(m,"CurrentTaskTargetZone")
 local freeBay=nil
 for i=1,9 do
  local blocked=bay_block_reason(autoCache[i],activeTarget)
  if not blocked then freeBay=i; break end
 end
 if not freeBay then
  return false
 end

 -- Any occupied hauled transporter slot is valid now: v0.12.9 proved dolly-owned
 -- and v0.13.0 proved truck-owned BeginCarUnloadSequence(runtime tag).
 local sourceSlot=nil
 local vehicle=nil
 local slotIndex=nil
 local sourceOwner=nil
 for i=1,7 do
  local slot=towCache[i]
  local v=source_vehicle(slot)
  if valid(v) and (boolprop(v,"IsHauled") or boolprop(v,"isHauled")) then
   sourceSlot=slot; vehicle=v; slotIndex=i; sourceOwner=attach_parent(slot); break
  end
 end
 if not valid(vehicle) or not valid(sourceSlot) then
  return false
 end

 local truck=nil
 pcall(function() truck=FindFirstOf("BP_TowTruckBig_C") end)
 if not valid(truck) then log(tostring(triggerLabel or "BATCH").." ABORT: BP_TowTruckBig_C not found") return false end

 local towTag=prop(sourceSlot,"TowSlotGameplayTag")
 if towTag==nil then log(tostring(triggerLabel or "BATCH").." ABORT: runtime TowSlotGameplayTag unavailable") return false end

 local function gameplay_tag_text(tag)
  if tag==nil then return "<nil>" end
  local out=nil
  pcall(function()
   local n=tag.TagName
   if n~=nil then
    local okName,nameText=pcall(function() return n:ToString() end)
    if okName and nameText~=nil then out=tostring(nameText) end
   end
  end)
  if out~=nil then return out end
  local okText,text=pcall(function() return tostring(tag) end)
  return okText and text or "<unreadable>"
 end

 moveBusy=true
 log("============================================================")
 log(tostring(triggerLabel or "BATCH").." ONE-CAR NATIVE UNLOAD -> AUTOMATION START | Slot "..slotIndex.." | batch next="..tostring(batchCompleted+1).."/"..tostring(batchTarget))
 log("SOURCE SLOT="..full(sourceSlot))
 log("SOURCE OWNER="..full(sourceOwner).." | class="..class_name(sourceOwner))
 log("VEHICLE="..full(vehicle).." | CarID="..car_id(vehicle))
 log("RUNTIME TowSlotGameplayTag="..gameplay_tag_text(towTag).." | reserved safe Automation Bay="..freeBay)
 log("BEFORE NATIVE UNLOAD | sourceOwns="..tostring(same_obj(source_vehicle(sourceSlot),vehicle))..
     " | IsHauled="..scalar_text(prop(vehicle,"IsHauled"))..
     " | AttachParent="..full(attach_parent(vehicle)))

 local ok,ret=pcall(function() return truck:BeginCarUnloadSequence(towTag) end)
 log("CALL BeginCarUnloadSequence(runtime TowSlotGameplayTag) | pcall="..tostring(ok).." | return="..tostring(ret))
 if not ok then
  log("CALL ERROR="..tostring(ret))
  moveBusy=false
  return false
 end

 pendingTransfer={
  vehicle=vehicle,
  sourceSlot=sourceSlot,
  slotIndex=slotIndex,
  worldGeneration=worldGeneration,
  checks=0
 }
 log("NATIVE UNLOAD STARTED | waiting for exact car to be source-empty + unhauled + detached before Automation handoff")
 log("NO MANUAL DETACH / NO MANUAL IsHauled EDIT / NO SOURCE SLOT CLEAR / NO MANAGER ARRAY MUTATION")
 log("============================================================")
 return true
end

-- Try to start the next queued car. This never unloads a car unless a safe Automation bay exists.
try_start_batch_next=function()
 if not batchActive or moveBusy or pendingTransfer~=nil then return end
 if batchCompleted>=batchTarget then
  log("AUTO BATCH COMPLETE | "..batchCompleted.."/"..batchTarget.." cars transferred | watcher remains "..(autoEnabled and "ON" or "OFF"))
  batchActive=false
  return
 end
 if not cacheReady or not towReady or not autoReady then return end
 if not transporter_is_home() then return end

 local m=get_manager()
 if not valid(m) then return end
 local activeTarget=objprop(m,"CurrentTaskTargetZone")
 local freeCount=0
 for i=1,9 do
  if not bay_block_reason(autoCache[i],activeTarget) then freeCount=freeCount+1 end
 end
 if freeCount<1 then
  if not batchWaitingForBayLogged then
   log("BATCH WAITING: no safe Automation bay available | remaining="..tostring(batchTarget-batchCompleted).." | transporter left untouched")
   batchWaitingForBayLogged=true
  end
  return
 end
 batchWaitingForBayLogged=false

 local hauledCount=0
 for i=1,7 do
  local v=source_vehicle(towCache[i])
  if valid(v) and (boolprop(v,"IsHauled") or boolprop(v,"isHauled")) then hauledCount=hauledCount+1 end
 end
 if hauledCount<1 then
  if not batchWaitingForCarLogged then
   log("ALL-CAR QUEUE STOPPED: no hauled transporter car remains | completed="..tostring(batchCompleted).."/"..tostring(batchTarget))
   batchWaitingForCarLogged=true
  end
  batchActive=false
  return
 end
 batchWaitingForCarLogged=false

 log("BATCH READY: safe Automation bays="..freeCount.." | starting car "..tostring(batchCompleted+1).."/"..tostring(batchTarget))
 local started=native_begin_unload_one("AUTO-BATCH")
 if not started then
  log("BATCH NEXT START DEFERRED | completed="..tostring(batchCompleted).."/"..tostring(batchTarget))
 end
end

local function arm_batch_from_current_transporter()
 if batchActive or moveBusy or pendingTransfer~=nil then return false end
 if not autoEnabled or not cacheReady or not towReady or not autoReady then return false end
 if not transporter_is_home() then
  homeStableTicks=0
  local key="AUTO_ON_AWAY"
  if lastStateKey~=key then
   lastStateKey=key
   log("AUTO WATCHER ON | transporter not at home anchors | waiting for return")
  end
  return false
 end

 homeStableTicks=homeStableTicks+1
 if homeStableTicks<2 then return false end

 local hauledNow=0
 for i=1,7 do
  local v=source_vehicle(towCache[i])
  if valid(v) and (boolprop(v,"IsHauled") or boolprop(v,"isHauled")) then hauledNow=hauledNow+1 end
 end
 if hauledNow<1 then
  local key="AUTO_ON_HOME_IDLE"
  if lastStateKey~=key then
   lastStateKey=key
   log("AUTO WATCHER ON | transporter home | no hauled cars onboard | waiting")
  end
  return false
 end

 lastStateKey=""
 batchActive=true
 batchTarget=hauledNow
 batchCompleted=0
 batchWaitingForBayLogged=false
 batchWaitingForCarLogged=false
 log("============================================================")
 log("AUTO TRANSPORTER DETECTED | target="..tostring(batchTarget).." hauled cars | starting persistent unload batch")
 log("RULE: one native unload at a time; wait safely whenever no Automation bay is free")
 log("============================================================")
 try_start_batch_next()
 return true
end

-- v0.16.0 automatic Side Parking -> Underground intake, adapted from protected v0.9.
local function retain_underground_zone(o)
 o=deref(o); if valid(o) and full(o):find("WorldMap:PersistentLevel",1,true) then undergroundZone=o; log("UNDERGROUND PARKING ZONE captured | "..full(o)) end
end
local function get_underground_zone() return valid(deref(undergroundZone)) and deref(undergroundZone) or nil end
garage_bool = function(method)
 local g=deref(undergroundGarage); if not valid(g) then return nil end
 local out={}; local ok=pcall(function() g[method](g,out) end); if not ok then return nil end
 for _,v in pairs(out) do if type(v)=="boolean" then return v end end
 return nil
end
local function side_get_parked_vehicle()
 local g=deref(undergroundGarage); if not valid(g) then return nil end
 local out={}; local ok=pcall(function() g:GetParkedVehicle(out) end); if not ok then return nil end
 for _,v in pairs(out) do v=deref(v); if valid(v) then return v end end
 return nil
end
local function dist2d2(x1,y1,x2,y2) local dx,dy=x1-x2,y1-y2; return dx*dx+dy*dy end
local function side_slot_xyz(slot)
 local out={}; local ok=pcall(function() slot:GetTransformForCar(out) end); if not ok then return nil,nil end
 local t=deref(out.Translation); if t==nil then return nil,nil end
 local x,y=nil,nil; pcall(function() x=tonumber(t.X); y=tonumber(t.Y) end); return x,y
end
local function find_side_vehicle()
 local m=get_manager(); if not valid(m) then return nil,nil,"Automation manager invalid" end
 local zones=prop(m,"ZoneActors"); if zones==nil then return nil,nil,"manager.ZoneActors unavailable" end
 local count=0; pcall(function() count=#zones end)
 local bestCar,bestSlot,bestD=nil,nil,999999999
 for zi=1,count do
  local raw=nil; pcall(function() raw=zones[zi] end); local slot=deref(raw)
  if valid(slot) then
   local car=objprop(slot,"ParkingSlotVehicle")
   if valid(car) and boolprop(slot,"ProperlyParked") then
    local x,y=side_slot_xyz(slot)
    if x and y then
     for _,p in ipairs(SIDE_POINTS) do
      local d=dist2d2(x,y,p[1],p[2]); if d<=260*260 and d<bestD then bestD=d; bestCar=car; bestSlot=slot end
     end
    end
   end
  end
 end
 if not valid(bestCar) then return nil,nil,"no properly parked Side Parking car" end
 return bestCar,bestSlot,nil
end
local function side_move_to_staging(car)
 local hit={}; local tr={Translation={X=UG_X,Y=UG_Y,Z=UG_Z},Rotation={Pitch=UG_PITCH,Yaw=UG_YAW,Roll=UG_ROLL},Scale3D={X=1,Y=1,Z=1}}
 local ok,e=pcall(function() car:K2_SetActorTransform(tr,false,hit,true) end); return ok,tostring(e or "")
end
local function side_finish(reason)
 if reason then log("SIDE INTAKE STOP | "..tostring(reason)) end
 sideBusy=false; sideCurrentCar=nil; sideCurrentCarId=nil; undergroundNextAllowedAt=os.time()+3
end
local side_start_next=nil
local function side_wait_store(carName,carId,attempt)
 if not sideBusy then return end
 local proper=garage_bool("HasProperlyParkedVehicle"); local parked=side_get_parked_vehicle(); local parkedName=full(parked)
 if not (proper==true and parkedName==carName) then
  sideTransferred=sideTransferred+1
  if carId and sessionJobs[carId] then
   completedThisSession=completedThisSession+1; sessionProcessed[carId]=true; sessionJobs[carId]=nil
   log("COMPLETED THIS SESSION +1 | CarID="..carId.." | completed="..completedThisSession)
  else
   log("SIDE -> UNDERGROUND STORED | manual/untracked CarID="..tostring(carId).." | not counted as session completion")
  end
  ExecuteWithDelay(2500,function() ExecuteInGameThread(function()
   if not sideBusy then return end
   local blocked=garage_bool("IsZoneBlocked"); local properNow=garage_bool("HasProperlyParkedVehicle"); local parkedNow=side_get_parked_vehicle()
   if blocked==true or properNow==true or valid(parkedNow) then
    ExecuteWithDelay(1500,function() ExecuteInGameThread(function() side_wait_store(carName,carId,attempt+1) end) end); return
   end
   side_start_next()
  end) end); return
 end
 if attempt>=30 then side_finish("timed out waiting for native Underground storage to clear"); return end
 ExecuteWithDelay(1000,function() ExecuteInGameThread(function() side_wait_store(carName,carId,attempt+1) end) end)
end
local function side_start_car(car,slot)
 sideCurrentCar=full(car); sideCurrentCarId=car_id(car)
 local expectedCarName=sideCurrentCar
 log("SIDE AUTO INTAKE | CarID="..tostring(sideCurrentCarId).." | car="..sideCurrentCar.." | 5s driver-exit grace period")
 -- Release safety: a manually driven car can become ProperlyParked while the player
 -- is still sitting in it. Do not teleport it immediately. Give the player time to
 -- exit, then re-confirm that the same car is still properly parked in Side Parking.
 ExecuteWithDelay(5000,function() ExecuteInGameThread(function()
  if not sideBusy then return end
  if not valid(car) then side_finish("Side car became invalid during driver-exit grace period"); return end
  local stillCar,stillSlot=find_side_vehicle()
  if not valid(stillCar) or full(stillCar)~=expectedCarName then
   side_finish("Side car left/moved during driver-exit grace period")
   return
  end
  log("SIDE DRIVER-EXIT GRACE PASSED | CarID="..tostring(sideCurrentCarId).." | same car still properly parked")
  local ok,e=side_move_to_staging(car); if not ok then side_finish("movement failed: "..e); return end
  local z=get_underground_zone(); if not valid(z) then side_finish("Underground parking zone not captured"); return end
  local ok1,e1=pcall(function() z:SetOverlappingVehicle(car) end); if not ok1 then side_finish("SetOverlappingVehicle failed: "..tostring(e1)); return end
  local ok2,e2=pcall(function() z:SetParkingSlotVehicle(car,true) end); if not ok2 then side_finish("SetParkingSlotVehicle failed: "..tostring(e2)); return end
  ExecuteWithDelay(750,function() ExecuteInGameThread(function()
   if not sideBusy then return end
   local zz=get_underground_zone(); if not valid(zz) then side_finish("zone invalid before CheckVehicles"); return end
   local out={}; local okc,ec=pcall(function() zz:CheckVehicles(out) end); if not okc then side_finish("CheckVehicles failed: "..tostring(ec)); return end
   local function verify(attempt)
    if not sideBusy then return end
    local proper=garage_bool("HasProperlyParkedVehicle"); local parked=side_get_parked_vehicle()
    if proper==true and valid(parked) and full(parked)==full(car) then
     local g=deref(undergroundGarage); local oks,es=pcall(function() g:OnStoreCarButtonPressed() end)
     if not oks then side_finish("OnStoreCarButtonPressed failed: "..tostring(es)); return end
     log("SIDE NATIVE STORE STARTED | CarID="..tostring(sideCurrentCarId))
     ExecuteWithDelay(1000,function() ExecuteInGameThread(function() side_wait_store(full(car),sideCurrentCarId,1) end) end); return
    end
    if attempt>=8 then side_finish("garage did not verify exact Side car"); return end
    ExecuteWithDelay(1000,function() ExecuteInGameThread(function() verify(attempt+1) end) end)
   end
   ExecuteWithDelay(750,function() ExecuteInGameThread(function() verify(1) end) end)
  end) end)
 end) end)
end
side_start_next=function()
 if not sideBusy then return end
 local car,slot,err=find_side_vehicle()
 if not valid(car) then side_finish(nil); return end
 side_start_car(car,slot)
end
local function start_side_intake_if_needed()
 if sideBusy then return false,"Side intake active" end
 if undergroundPending~=nil then return false,"Underground retrieval active" end
 local g=deref(undergroundGarage); local z=get_underground_zone(); if not valid(g) or not valid(z) then return false,"Underground intake refs not captured" end
 local blocked=garage_bool("IsZoneBlocked"); local proper=garage_bool("HasProperlyParkedVehicle"); local parked=side_get_parked_vehicle()
 if blocked==true or proper==true or valid(parked) then return false,"Underground intake busy" end
 local car,slot,err=find_side_vehicle(); if not valid(car) then return false,err end
 sideBusy=true; side_start_car(car,slot); return true,nil
end

local function main_tick()
 if tickBusy then return end
 tickBusy=true
 local ok,err=pcall(function()
  if not cacheReady then cache_tick() end
  if cacheReady and pendingTransfer~=nil then pending_transfer_tick() end
  if cacheReady and undergroundPending~=nil then underground_transfer_tick() end
  if cacheReady and batchActive and pendingTransfer==nil and not moveBusy then try_start_batch_next() end

  -- v0.16.0 SMART LOOP idle priority:
  -- 1) Transporter cars, 2) Side Parking intake, 3) NEEDS WORK Underground cars.
  -- Native Underground IN and OUT are never started at the same time.
  if cacheReady and autoEnabled and undergroundPending==nil and not sideBusy and not batchActive and pendingTransfer==nil and not moveBusy then
   local sourceCount,freeCount=current_counts(objprop(get_manager(),"CurrentTaskTargetZone"))
   if sourceCount>0 then
    local armed=arm_batch_from_current_transporter()
    if armed then log("MASTER FEED PRIORITY | transporter cars detected -> transporter batch armed first") end
   else
    local sideStarted,sideErr=start_side_intake_if_needed()
    if sideStarted then
     lastSideWaitReason=""
     lastUndergroundWaitReason=""
    elseif freeCount>0 then
     local now=os.time()
     if now >= (undergroundNextAllowedAt or 0) then
      local started,uerr=start_next_random_underground()
      if not started then
       local msg=tostring(uerr)
       if msg~=lastUndergroundWaitReason then log("MASTER FEED UNDERGROUND WAIT | "..msg); lastUndergroundWaitReason=msg end
      else
       lastUndergroundWaitReason=""
      end
     end
    else
     if lastUndergroundWaitReason~="Automation full" then
      log("MASTER FEED WAIT | Automation has no safe free bay; watcher remains ON")
      lastUndergroundWaitReason="Automation full"
     end
    end
   end
  end
  ui_poll_command()
  ui_write_state()
 end)
 if not ok then log("AUTO TICK ERROR: "..tostring(err)) end
 tickBusy=false
end

mkdir()
local f=io.open(LOG_PATH,"w")
if f then
 f:write("JJ's Vehicle Mover v0.16.21\n")
 f:write("SMART LOOP: TRANSPORTER + NEEDS-WORK UNDERGROUND -> AUTOMATION + SIDE -> UNDERGROUND\n")
 f:write("ZERO FindAllOf | F9 persistent master feed ON/OFF\n\n")
 f:close()
end

log("Loaded v0.16.21 | release candidate | garage-idle scope fix + Side grace + single-instance UI")
log("v0.16.4: protected v0.15.2 timing preserved | protected Side->Underground v0.9 native path integrated")
log("ZERO FindAllOf anywhere in this build.")
log("MASTER FEED starts OFF. F9 toggles persistent feed ON/OFF; ON keeps feeding until switched OFF.")
log("F6=DEEP snapshot | F9=MASTER FEED ON/OFF | transporter priority, then Underground when transporter is empty")

local okNotify,retNotify=pcall(function()
 return NotifyOnNewObject(TOW_CLASS_PATH,function(o)
  local ok2,err=pcall(function() retain_tow(o) end)
  if not ok2 then log("NOTIFY callback error: "..tostring(err)) end
 end)
end)
if okNotify then
 notifyRegistered=true
 log("NotifyOnNewObject registration succeeded | return="..tostring(retNotify))
else
 log("NotifyOnNewObject registration FAILED: "..tostring(retNotify))
end

local okTMNotify,retTMNotify=pcall(function()
 return NotifyOnNewObject(TRANSPORTER_MANAGER_CLASS_PATH,function(o)
  local ok2,err=pcall(function() retain_transporter_manager(o) end)
  if not ok2 then log("TRANSPORTER MANAGER notify callback error: "..tostring(err)) end
 end)
end)
if okTMNotify then
 transporterManagerNotifyRegistered=true
 log("Transporter-manager NotifyOnNewObject registration succeeded | return="..tostring(retTMNotify))
else
 log("Transporter-manager NotifyOnNewObject registration FAILED: "..tostring(retTMNotify))
end

local okUGNotify,retUGNotify=pcall(function()
 return NotifyOnNewObject(UNDERGROUND_GARAGE_CLASS_PATH,function(o)
  local ok2,err=pcall(function() retain_underground_garage(o) end)
  if not ok2 then log("UNDERGROUND GARAGE notify callback error: "..tostring(err)) end
 end)
end)
if okUGNotify then
 undergroundNotifyRegistered=true
 log("Underground Garage NotifyOnNewObject registration succeeded | return="..tostring(retUGNotify))
else
 log("Underground Garage NotifyOnNewObject registration FAILED: "..tostring(retUGNotify))
end

local okUSNotify,retUSNotify=pcall(function()
 return NotifyOnNewObject(UNDERGROUND_STORAGE_CLASS_PATH,function(o)
  local ok2,err=pcall(function() retain_underground_storage(o) end)
  if not ok2 then log("UNDERGROUND STORAGE notify callback error: "..tostring(err)) end
 end)
end)
if okUSNotify then
 undergroundStorageNotifyRegistered=true
 log("Underground Storage NotifyOnNewObject registration succeeded | return="..tostring(retUSNotify))
else
 log("Underground Storage NotifyOnNewObject registration FAILED: "..tostring(retUSNotify))
end

local okUZNotify,retUZNotify=pcall(function()
 return NotifyOnNewObject(UNDERGROUND_ZONE_CLASS_PATH,function(o)
  local ok2,err=pcall(function() retain_underground_zone(o) end)
  if not ok2 then log("UNDERGROUND ZONE notify callback error: "..tostring(err)) end
 end)
end)
if okUZNotify then log("Underground Zone NotifyOnNewObject registration succeeded | return="..tostring(retUZNotify)) else log("Underground Zone NotifyOnNewObject registration FAILED: "..tostring(retUZNotify)) end

-- Clear stale world refs BEFORE a save/map load. NotifyOnNewObject then repopulates them.
pcall(function()
 RegisterLoadMapPreHook(function()
  reset_world_state("LoadMapPreHook")
 end)
end)

pcall(function()
 RegisterLoadMapPostHook(function()
  log("LoadMapPostHook | waiting for notified tow refs and Automation manager")
 end)
end)

RegisterKeyBind(Key.F6,function()
 ExecuteInGameThread(function()
  local ok,err=pcall(deep_status_snapshot)
  if not ok then log("F6 STATUS ERROR: "..tostring(err)) end
 end)
end)

toggle_master_feed=function(trigger)
 local ok,err=pcall(function()
  if autoEnabled then
   autoEnabled=false
   integrationTestActive=false
   batchActive=false
   batchWaitingForBayLogged=false
   batchWaitingForCarLogged=false
   homeStableTicks=0
   lastStateKey=""
   log("============================================================")
   if pendingTransfer~=nil or moveBusy or undergroundPending~=nil or sideBusy then
    log(tostring(trigger or "F9").." MASTER FEED OFF | current in-flight car will finish safely; no further cars will start")
   else
    log(tostring(trigger or "F9").." MASTER FEED OFF | no further transporter or Underground cars will start")
   end
   log("============================================================")
   ui_write_state()
   return
  end

  if not cacheReady then log(tostring(trigger or "F9").." MASTER FEED ABORTED: cache not ready yet"); return end
  if not valid(deref(undergroundGarage)) or not valid(deref(undergroundStorage)) then
   log(tostring(trigger or "F9").." MASTER FEED ABORTED: Underground Garage/storage not captured yet"); return
  end
  local sourceCount,freeCount=current_counts(objprop(get_manager(),"CurrentTaskTargetZone"))
  autoEnabled=true
  integrationTestActive=true
  integrationTransporterDone=false
  integrationUndergroundCompleted=0
  sessionJobs={}; sessionProcessed={}
  completedThisSession=0; sideTransferred=0; sentToAutomationSession=0
  undergroundNextAllowedAt=0; lastUndergroundWaitReason=""
  batchActive=false; batchTarget=0; batchCompleted=0
  batchWaitingForBayLogged=false; batchWaitingForCarLogged=false
  homeStableTicks=0; lastStateKey=""
  log("============================================================")
  log(tostring(trigger or "F9").." MASTER FEED ON | hauled transporter cars="..tostring(sourceCount).." | free Automation bays="..tostring(freeCount))
  log("PRIORITY: transporter first -> automatic Side intake -> NEEDS WORK Underground -> continue until switched OFF")
  log("Underground StoredCars will only be enumerated while the native garage is idle; UI readiness refresh is throttled")
  log("============================================================")
  ui_write_state()
  main_tick()
 end)
 if not ok then log(tostring(trigger or "F9").." AUTO WATCHER ERROR: "..tostring(err)) end
end

RegisterKeyBind(Key.F9,function()
 ExecuteInGameThread(function() toggle_master_feed("F9") end)
end)


-- Lightweight 2-second watcher. UObject work is marshalled to the game thread.
-- It never walks global UObject arrays. Once cacheReady, each idle pass only checks
-- cached 7 tow slots + cached 9 Automation bays + CurrentTaskTargetZone.
LoopAsync(2000,function()
 local ok,err=pcall(function()
  ExecuteInGameThread(function()
   main_tick()
  end)
 end)
 if not ok then log("LOOP scheduling error: "..tostring(err)) end
 return false
end)
