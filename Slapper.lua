local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local TOOL_NAME = "Phalanx ciws"
local SLAP_TOOL_NAME = "GreenSlap"
local LOOP_DELAY = 0.010
local SLAP_COOLDOWN = 0.010
local BARREL_SPIN_SPEED = 36
local MOVE_SPEED = 24 -- studs/sec when moving the CIWS
local FALLBACK_VEC = Vector3.new(-2.67, -4.03, -3.55)

local TARGET_MODES = { "RANDOM", "ALL", "PLAYER", "AIM", "AURA" }

local equipped = false
local holdingFire = false
local autoFireEnabled = false
local lastSlapTime = 0
local lastTracerTime = 0
local lastRandomSwitchTime = 0
local activeRandomTargetPlr = nil
local aimHitPlayerNames = {}
local auraRadius = 16
local savedVisibility = {}

local targetModeIndex = 1 -- 1: RANDOM, 2: ALL, 3: PLAYER, 4: AIM, 5: AURA
local selectedPlayerNames = {}

local turretFolder = nil
local turretParts = {}
local barrelItems = {}
local barrelIndex = 1
local spinAngle = 0
local turretPos = nil
local turretYaw = 0
local upperYaw = 0
local gunPitch = 0
local fireGui = nil
local holdBtn = nil
local modeBtn = nil
local autoFireBtn = nil
local pickerFrame = nil
local auraFrame = nil
local connections = {}

local function trackConn(conn)
	table.insert(connections, conn)
	return conn
end

local function clearConnections()
	for _, conn in ipairs(connections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(connections)
end

local function getChar()
	return LocalPlayer.Character
end

local function getRoot()
	local char = getChar()
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
	local char = getChar()
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- Client-side character visibility toggle
local function setClientCharacterInvisible(makeInvisible)
	local char = getChar()
	if not char then
		return
	end

	if makeInvisible then
		table.clear(savedVisibility)
		for _, desc in ipairs(char:GetDescendants()) do
			if desc:IsA("BasePart") or desc:IsA("Decal") then
				savedVisibility[desc] = {
					Transparency = desc.Transparency,
					LocalTransparencyModifier = desc:IsA("BasePart") and desc.LocalTransparencyModifier or nil,
				}
				desc.Transparency = 1
				if desc:IsA("BasePart") then
					desc.LocalTransparencyModifier = 1
				end
			elseif desc:IsA("BillboardGui") or desc:IsA("SurfaceGui") then
				savedVisibility[desc] = {
					Enabled = desc.Enabled,
				}
				desc.Enabled = false
			end
		end
	else
		for inst, state in pairs(savedVisibility) do
			if inst and inst.Parent then
				if (inst:IsA("BasePart") or inst:IsA("Decal")) and state.Transparency ~= nil then
					inst.Transparency = state.Transparency
					if inst:IsA("BasePart") and state.LocalTransparencyModifier ~= nil then
						inst.LocalTransparencyModifier = state.LocalTransparencyModifier
					end
				elseif (inst:IsA("BillboardGui") or inst:IsA("SurfaceGui")) and state.Enabled ~= nil then
					inst.Enabled = state.Enabled
				end
			end
		end
		table.clear(savedVisibility)
	end
end

-- GreenSlap Remote Lookup (works even if LocalPlayer doesn't own/have GreenSlap)
local function findEventInTool(tool)
	if not tool then
		return nil
	end
	local ev = tool:FindFirstChild("Event")
	if ev and ev:IsA("RemoteEvent") then
		return ev
	end
	for _, desc in ipairs(tool:GetDescendants()) do
		if desc:IsA("RemoteEvent") then
			return desc
		end
	end
	return nil
end

local function getSlapEvent()
	local char = getChar()
	if char then
		local ev = findEventInTool(char:FindFirstChild(SLAP_TOOL_NAME))
		if ev then
			return ev
		end
	end

	local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
	if backpack then
		local ev = findEventInTool(backpack:FindFirstChild(SLAP_TOOL_NAME))
		if ev then
			return ev
		end
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			if plr.Character then
				local ev = findEventInTool(plr.Character:FindFirstChild(SLAP_TOOL_NAME))
				if ev then
					return ev
				end
			end
			local otherBp = plr:FindFirstChildOfClass("Backpack")
			if otherBp then
				local ev = findEventInTool(otherBp:FindFirstChild(SLAP_TOOL_NAME))
				if ev then
					return ev
				end
			end
		end
	end

	for _, container in ipairs({ ReplicatedStorage, workspace }) do
		for _, desc in ipairs(container:GetDescendants()) do
			if desc.Name == SLAP_TOOL_NAME then
				local ev = findEventInTool(desc)
				if ev then
					return ev
				end
			elseif desc:IsA("RemoteEvent") and desc.Parent and desc.Parent.Name == SLAP_TOOL_NAME then
				return desc
			end
		end
	end

	if typeof(getnilinstances) == "function" then
		local ok, nilList = pcall(getnilinstances)
		if ok and type(nilList) == "table" then
			for _, obj in ipairs(nilList) do
				if typeof(obj) == "Instance" and obj:IsA("RemoteEvent") and obj.Parent and obj.Parent.Name == SLAP_TOOL_NAME then
					return obj
				end
			end
		end
	end

	for _, container in ipairs({ ReplicatedStorage, workspace }) do
		for _, desc in ipairs(container:GetDescendants()) do
			if desc:IsA("RemoteEvent") then
				local n = string.lower(desc.Name)
				local pName = desc.Parent and string.lower(desc.Parent.Name) or ""
				if string.find(n, "slap", 1, true)
					or string.find(n, "slash", 1, true)
					or string.find(n, "hit", 1, true)
					or string.find(pName, "slap", 1, true)
				then
					return desc
				end
			end
		end
	end

	return nil
end

local function getTargetRoot(targetChar)
	if not targetChar then
		return nil
	end
	return targetChar:FindFirstChild("HumanoidRootPart")
		or targetChar:FindFirstChild("Torso")
		or targetChar:FindFirstChild("UpperTorso")
end

local function getCurrentTargetMode()
	return TARGET_MODES[targetModeIndex] or "RANDOM"
end

local function isPlayerAliveAndValid(plr)
	if not plr or plr == LocalPlayer or not plr.Character or not plr.Character.Parent then
		return false
	end
	local hum = plr.Character:FindFirstChildOfClass("Humanoid")
	local tRoot = getTargetRoot(plr.Character)
	return tRoot ~= nil and (not hum or hum.Health > 0)
end

local function pickRandomPlayer()
	local candidates = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if isPlayerAliveAndValid(plr) then
			table.insert(candidates, plr)
		end
	end
	if #candidates == 0 then
		return nil
	end
	if #candidates == 1 then
		return candidates[1]
	end
	local filtered = {}
	for _, plr in ipairs(candidates) do
		if plr ~= activeRandomTargetPlr then
			table.insert(filtered, plr)
		end
	end
	local pool = (#filtered > 0) and filtered or candidates
	return pool[math.random(1, #pool)]
end

local function getAuraPlayers()
	local inAura = {}
	local origin = turretPos or (getRoot() and getRoot().Position)
	if not origin then
		return inAura
	end

	for _, plr in ipairs(Players:GetPlayers()) do
		if isPlayerAliveAndValid(plr) then
			local tRoot = getTargetRoot(plr.Character)
			if tRoot then
				local dist = (tRoot.Position - origin).Magnitude
				if dist >= 0 and dist <= auraRadius then
					table.insert(inAura, plr)
				end
			end
		end
	end

	return inAura
end

local function getActiveTargetPlayers()
	local mode = getCurrentTargetMode()
	local list = {}

	if mode == "RANDOM" then
		local now = os.clock()
		if not isPlayerAliveAndValid(activeRandomTargetPlr) or (now - lastRandomSwitchTime >= 1.25) then
			activeRandomTargetPlr = pickRandomPlayer()
			lastRandomSwitchTime = now
		end
		if isPlayerAliveAndValid(activeRandomTargetPlr) then
			table.insert(list, activeRandomTargetPlr)
		end
		return list
	elseif mode == "PLAYER" then
		for _, plr in ipairs(Players:GetPlayers()) do
			if selectedPlayerNames[plr.Name] and isPlayerAliveAndValid(plr) then
				table.insert(list, plr)
			end
		end
		return list
	elseif mode == "AIM" then
		for _, plr in ipairs(Players:GetPlayers()) do
			if aimHitPlayerNames[plr.Name] and isPlayerAliveAndValid(plr) then
				table.insert(list, plr)
			end
		end
		return list
	elseif mode == "AURA" then
		return getAuraPlayers()
	else
		-- "ALL" targets all other valid players in the server
		for _, plr in ipairs(Players:GetPlayers()) do
			if isPlayerAliveAndValid(plr) then
				table.insert(list, plr)
			end
		end
		return list
	end
end

local function getAllTargetRoots()
	local roots = {}
	for _, plr in ipairs(getActiveTargetPlayers()) do
		local tRoot = getTargetRoot(plr.Character)
		if tRoot then
			table.insert(roots, tRoot)
		end
	end
	return roots
end

local function getPrimaryAimTargetRoot()
	local myRoot = getRoot()
	local activePlayers = getActiveTargetPlayers()
	local bestRoot = nil
	local bestDist = math.huge

	for _, plr in ipairs(activePlayers) do
		local tRoot = getTargetRoot(plr.Character)
		if tRoot then
			if myRoot then
				local d = (tRoot.Position - myRoot.Position).Magnitude
				if d < bestDist then
					bestDist = d
					bestRoot = tRoot
				end
			else
				return tRoot
			end
		end
	end

	return bestRoot
end

local function getTargetVector(targetChar)
	local myRoot = getRoot()
	local tRoot = getTargetRoot(targetChar)
	if myRoot and tRoot then
		local delta = tRoot.Position - myRoot.Position
		if delta.Magnitude > 0.001 then
			return delta.Unit * 5
		end
	end
	return FALLBACK_VEC
end

local function triggerSlapRemote()
	local now = os.clock()
	if now - lastSlapTime < SLAP_COOLDOWN then
		return
	end

	local event = getSlapEvent()
	lastSlapTime = now

	local targets = (getCurrentTargetMode() == "AURA") and getAuraPlayers() or getActiveTargetPlayers()
	for _, plr in ipairs(targets) do
		if not holdingFire or not equipped then
			break
		end
		local targetChar = plr.Character
		if targetChar and targetChar.Parent then
			local vecArg = getTargetVector(targetChar)
			if event then
				pcall(function()
					event:FireServer("slash", targetChar, vecArg)
				end)
			end
		end
	end
end

-- Turret Builder (wheels removed, bigger and taller head)
local function destroyTurret()
	if turretFolder and turretFolder.Parent then
		turretFolder:Destroy()
	end
	turretFolder = nil
	table.clear(turretParts)
	table.clear(barrelItems)
	barrelIndex = 1
	spinAngle = 0
	turretPos = nil
	turretYaw = 0
	upperYaw = 0
	gunPitch = 0
	activeRandomTargetPlr = nil
end

local function makeVisiblePart(parent, name, size, color, material, shape)
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.Metal
	p.Transparency = 0
	p.LocalTransparencyModifier = 0
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function createTurret(startPos, startYaw)
	destroyTurret()

	turretPos = startPos
	turretYaw = startYaw
	upperYaw = startYaw
	gunPitch = 0

	local folder = Instance.new("Folder")
	folder.Name = "VisiblePhalanxCIWS"
	folder.Parent = workspace

	local chassis = makeVisiblePart(folder, "Chassis", Vector3.new(4.6, 1.0, 5.4), Color3.fromRGB(120, 126, 134), Enum.Material.Metal)
	local pedestal = makeVisiblePart(folder, "Pedestal", Vector3.new(3.6, 1.8, 3.6), Color3.fromRGB(155, 162, 170), Enum.Material.Metal)
	local body = makeVisiblePart(folder, "TurretHousing", Vector3.new(4.6, 3.0, 5.0), Color3.fromRGB(220, 224, 230), Enum.Material.SmoothPlastic)
	local neck = makeVisiblePart(folder, "RadomeMast", Vector3.new(1.8, 2.4, 1.8), Color3.fromRGB(170, 176, 184), Enum.Material.Metal)
	local radome = makeVisiblePart(folder, "RadomeHead", Vector3.new(6.0, 4.6, 5.8), Color3.fromRGB(246, 248, 252), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local seat = makeVisiblePart(folder, "SeatMount", Vector3.new(2.4, 0.4, 2.2), Color3.fromRGB(45, 48, 54), Enum.Material.DiamondPlate)
	local shroud = makeVisiblePart(folder, "BarrelShroud", Vector3.new(1.7, 1.7, 3.0), Color3.fromRGB(68, 74, 82), Enum.Material.Metal)

	turretParts = {
		chassis = chassis,
		pedestal = pedestal,
		body = body,
		neck = neck,
		radome = radome,
		seat = seat,
		shroud = shroud,
	}

	-- 6 Rotating Barrels
	local barrelOffsets = {
		Vector3.new(0, 0.52, 0),
		Vector3.new(0.45, 0.26, 0),
		Vector3.new(0.45, -0.26, 0),
		Vector3.new(0, -0.52, 0),
		Vector3.new(-0.45, -0.26, 0),
		Vector3.new(-0.45, 0.26, 0),
	}

	barrelItems = {}
	for i, off in ipairs(barrelOffsets) do
		local b = makeVisiblePart(folder, "Barrel_" .. i, Vector3.new(6.0, 0.22, 0.22), Color3.fromRGB(36, 39, 44), Enum.Material.Metal, Enum.PartType.Cylinder)
		table.insert(barrelItems, { part = b, offset = off })
	end

	turretFolder = folder
end

local function getMoveInputVector()
	local moveX = 0
	local moveZ = 0

	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		moveZ -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		moveZ += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		moveX -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		moveX += 1
	end

	local hum = getHumanoid()
	if hum and hum.MoveDirection.Magnitude > 0.05 then
		local cam = workspace.CurrentCamera
		if cam then
			local camLook = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
			local camRight = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
			if camLook.Magnitude > 0.001 and camRight.Magnitude > 0.001 then
				local rel = camRight.Unit * hum.MoveDirection.X + camLook.Unit * (-hum.MoveDirection.Z)
				return rel.Magnitude > 1 and rel.Unit or rel
			end
		end
	end

	local vec = Vector3.new(moveX, 0, moveZ)
	if vec.Magnitude > 0.001 then
		local cam = workspace.CurrentCamera
		if cam then
			local camLook = Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z)
			local camRight = Vector3.new(cam.CFrame.RightVector.X, 0, cam.CFrame.RightVector.Z)
			if camLook.Magnitude > 0.001 and camRight.Magnitude > 0.001 then
				local worldMove = (camRight.Unit * vec.X) + (camLook.Unit * (-vec.Z))
				return worldMove.Magnitude > 1 and worldMove.Unit or worldMove
			end
		end
		return vec.Unit
	end

	return Vector3.zero
end

local function checkBulletHitPlayer(pos)
	for _, plr in ipairs(Players:GetPlayers()) do
		if isPlayerAliveAndValid(plr) then
			local tRoot = getTargetRoot(plr.Character)
			if tRoot and (tRoot.Position - pos).Magnitude <= 5.5 then
				aimHitPlayerNames[plr.Name] = true
			end
		end
	end
end

local function launchBullet(tipPos, dir)
	local bullet = Instance.new("Part")
	bullet.Name = "CIWS_BarrelBullet"
	bullet.Size = Vector3.new(0.24, 0.24, 3.8)
	bullet.Color = Color3.fromRGB(255, 215, 70)
	bullet.Material = Enum.Material.Neon
	bullet.Anchored = true
	bullet.CanCollide = false
	bullet.CanTouch = false
	bullet.CanQuery = false
	bullet.CFrame = CFrame.lookAt(tipPos + dir * 1.5, tipPos + dir * 5.0)
	bullet.Parent = workspace

	task.spawn(function()
		local dist = 0
		local speed = 320
		local maxDist = 160
		while bullet.Parent and dist < maxDist do
			local dt = RunService.Heartbeat:Wait()
			local step = speed * dt
			dist += step
			local pos = bullet.CFrame.Position + dir * step
			bullet.CFrame = CFrame.lookAt(pos, pos + dir)
			checkBulletHitPlayer(pos)
		end
		if bullet.Parent then
			bullet:Destroy()
		end
	end)
end

local function spawnBulletFromBarrel(barrelPart, targetRoot)
	if not barrelPart or not barrelPart.Parent then
		return
	end

	-- Barrel cylinder has its length along its local X axis; tip is at +X half-length (3.0 studs)
	local tipPos = barrelPart.CFrame:PointToWorldSpace(Vector3.new(3.1, 0, 0))
	if targetRoot then
		local toTarget = targetRoot.Position - tipPos
		if toTarget.Magnitude > 0.1 then
			launchBullet(tipPos, toTarget.Unit)
			return
		end
	end

	launchBullet(tipPos, barrelPart.CFrame.RightVector)
end

local function fireFromEveryBarrel()
	local allTargets = getAllTargetRoots()
	for i, bItem in ipairs(barrelItems) do
		if bItem and bItem.part then
			local chosenTarget = (#allTargets > 0) and allTargets[((i - 1) % #allTargets) + 1] or nil
			spawnBulletFromBarrel(bItem.part, chosenTarget)
		end
	end
end

local function updateTurret(dt)
	if not turretFolder or not turretFolder.Parent or not turretPos then
		return
	end

	local root = getRoot()
	local hum = getHumanoid()
	if not root or not hum then
		return
	end

	if hum.Health > 0 and not hum.Sit then
		hum.Sit = true
	end

	local effectiveMoveSpeed = (hum.WalkSpeed and hum.WalkSpeed > 0) and hum.WalkSpeed or MOVE_SPEED

	-- Move turret horizontally without jumping (Y stays locked)
	local moveDir = getMoveInputVector()
	if moveDir.Magnitude > 0.001 then
		local stepVec = moveDir * effectiveMoveSpeed * dt
		turretPos = Vector3.new(turretPos.X + stepVec.X, turretPos.Y, turretPos.Z + stepVec.Z)

		turretYaw = math.atan2(-moveDir.X, -moveDir.Z)
		if not holdingFire then
			upperYaw = turretYaw
			gunPitch = 0
		end
	end

	local baseCF = CFrame.new(turretPos) * CFrame.Angles(0, turretYaw, 0)
	local chassisOffset = Vector3.new(0, -1.65, -1.6)
	local chassisWorldPos = (baseCF * CFrame.new(chassisOffset)).Position

	-- Rotate upper body/head/shroud/barrels (target yaw + up-only pitch) around the grey bottom block
	if holdingFire then
		spinAngle = (spinAngle + BARREL_SPIN_SPEED * dt) % (math.pi * 2)

		local aimRoot = getPrimaryAimTargetRoot()
		if aimRoot then
			local gunPivotPos = chassisWorldPos + Vector3.new(0, 2.45, 0)
			local toTarget = aimRoot.Position - gunPivotPos
			local flatToTarget = Vector3.new(toTarget.X, 0, toTarget.Z)
			if flatToTarget.Magnitude > 0.05 then
				upperYaw = math.atan2(-flatToTarget.X, -flatToTarget.Z)
			end
			-- Pitch ONLY when target is above (positive elevation); never tilt downward
			local rawPitch = math.atan2(toTarget.Y, math.max(flatToTarget.Magnitude, 0.05))
			gunPitch = math.clamp(math.max(0, rawPitch), 0, 0.78)
		else
			upperYaw = turretYaw
			gunPitch = 0
		end

		local now = os.clock()
		if now - lastTracerTime >= 0.015 and #barrelItems > 0 then
			lastTracerTime = now
			barrelIndex = (barrelIndex % #barrelItems) + 1
			fireFromEveryBarrel()
		end
	else
		upperYaw = turretYaw
		gunPitch = 0
	end

	-- Upper assembly pivots around the grey block center with target yaw AND up-only pitch
	local upperBodyCF = CFrame.new(chassisWorldPos + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, upperYaw, 0) * CFrame.Angles(gunPitch, 0, 0)

	-- Grey base stays level and anchored to baseCF; upper body + player pitch together
	turretParts.chassis.CFrame = baseCF * CFrame.new(chassisOffset)

	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = upperBodyCF * CFrame.new(0, 1.75, 2.0)

	turretParts.seat.CFrame = upperBodyCF * CFrame.new(0, 1.05, 2.0)
	turretParts.pedestal.CFrame = upperBodyCF * CFrame.new(0, 0.45, -0.2)
	turretParts.body.CFrame = upperBodyCF * CFrame.new(0, 1.85, -0.2)
	turretParts.neck.CFrame = upperBodyCF * CFrame.new(0, 4.35, -0.3)
	turretParts.radome.CFrame = upperBodyCF * CFrame.new(0, 7.15, -0.3) -- bigger & taller head
	turretParts.shroud.CFrame = upperBodyCF * CFrame.new(0, 1.95, -3.2)

	-- Spin 6 barrels with the pitched upper body
	local spinCF = CFrame.Angles(0, 0, spinAngle)
	for _, bItem in ipairs(barrelItems) do
		local rotOff = spinCF * bItem.offset
		bItem.part.CFrame = upperBodyCF * CFrame.new(rotOff.X, rotOff.Y + 1.95, -4.6) * CFrame.Angles(0, math.pi / 2, 0)
	end
end

local function refreshFireButtonVisuals()
	if holdBtn then
		if holdingFire then
			holdBtn.BackgroundColor3 = Color3.fromRGB(240, 135, 25)
			holdBtn.Text = "FIRING..."
		else
			holdBtn.BackgroundColor3 = Color3.fromRGB(190, 40, 40)
			holdBtn.Text = "Hold to Fire"
		end
	end
	if autoFireBtn then
		if autoFireEnabled then
			autoFireBtn.BackgroundColor3 = Color3.fromRGB(45, 165, 85)
			autoFireBtn.Text = "Auto: ON"
		else
			autoFireBtn.BackgroundColor3 =Color3.fromRGB(65, 70, 80)
			autoFireBtn.Text = "Auto: OFF"
		end
	end
end

local function closeSubGuis()
	if pickerFrame and pickerFrame.Parent then
		pickerFrame:Destroy()
	end
	pickerFrame = nil
	if auraFrame and auraFrame.Parent then
		auraFrame:Destroy()
	end
	auraFrame = nil
end

-- Aura Stud Input GUI for "AURA" mode
local function openAuraStudGui()
	closeSubGuis()
	if not fireGui or not fireGui.Parent then
		return
	end

	local panel = Instance.new("Frame")
	panel.Name = "AuraStudPanel"
	panel.Size = UDim2.new(0, 230, 0, 130)
	panel.Position = UDim2.new(0.5, -115, 0.5, -110)
	panel.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.ZIndex = 10
	panel.Parent = fireGui
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 24)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.Text = "Aura Range (0 to Studs): " .. tostring(auraRadius)
	title.ZIndex = 11
	title.Parent = panel

	local studBox = Instance.new("TextBox")
	studBox.Name = "StudInputBox"
	studBox.Size = UDim2.new(1, -16, 0, 34)
	studBox.Position = UDim2.new(0, 8, 0, 36)
	studBox.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	studBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	studBox.PlaceholderText = "Enter studs (e.g. 16)"
	studBox.Text = tostring(auraRadius)
	studBox.Font = Enum.Font.GothamSemibold
	studBox.TextSize = 14
	studBox.ClearTextOnFocus = false
	studBox.BorderSizePixel = 0
	studBox.ZIndex = 12
	studBox.Parent = panel
	Instance.new("UICorner", studBox).CornerRadius = UDim.new(0, 6)

	local confirmBtn = Instance.new("TextButton")
	confirmBtn.Name = "ConfirmStudButton"
	confirmBtn.Size = UDim2.new(1, -16, 0, 36)
	confirmBtn.Position = UDim2.new(0, 8, 1, -44)
	confirmBtn.BackgroundColor3 = Color3.fromRGB(35, 125, 225)
	confirmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	confirmBtn.Font = Enum.Font.GothamBold
	confirmBtn.TextSize = 14
	confirmBtn.Text = "Confirm Stud"
	confirmBtn.BorderSizePixel = 0
	confirmBtn.ZIndex = 12
	confirmBtn.Parent = panel
	Instance.new("UICorner", confirmBtn).CornerRadius = UDim.new(0, 8)

	trackConn(confirmBtn.MouseButton1Click:Connect(function()
		local parsed = tonumber(studBox.Text)
		if parsed and parsed >= 0 then
			auraRadius = parsed
			title.Text = "Aura Range (0 to Studs): " .. tostring(auraRadius)
		end
		if auraFrame and auraFrame.Parent then
			auraFrame:Destroy()
			auraFrame = nil
		end
	end))

	auraFrame = panel
end

-- Player Picker GUI for "PLAYER" mode
local function openPlayerPickerGui()
	closeSubGuis()
	if not fireGui or not fireGui.Parent then
		return
	end

	local panel = Instance.new("Frame")
	panel.Name = "TargetPlayerPicker"
	panel.Size = UDim2.new(0, 250, 0, 280)
	panel.Position = UDim2.new(0.5, -125, 0.5, -195)
	panel.BackgroundColor3 = Color3.fromRGB(28, 30, 36)
	panel.BorderSizePixel = 0
	panel.Active = true
	panel.ZIndex = 10
	panel.Parent = fireGui
	Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 10)

	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -16, 0, 28)
	title.Position = UDim2.new(0, 8, 0, 6)
	title.BackgroundTransparency = 1
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.Text = "Select Target Players"
	title.ZIndex = 11
	title.Parent = panel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, -16, 1, -86)
	scroll.Position = UDim2.new(0, 8, 0, 38)
	scroll.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.ZIndex = 11
	scroll.Parent = panel
	Instance.new("UICorner", scroll).CornerRadius = UDim.new(0, 8)

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local function refreshRowVisual(btn, plrName)
		local picked = selectedPlayerNames[plrName] == true
		btn.BackgroundColor3 = picked and Color3.fromRGB(45, 155, 85) or Color3.fromRGB(50, 54, 62)
		btn.Text = (picked and "[✓] " or "[ ] ") .. plrName
	end

	local otherPlayers = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr ~= LocalPlayer then
			table.insert(otherPlayers, plr)
		end
	end
	table.sort(otherPlayers, function(a, b)
		return string.lower(a.Name) < string.lower(b.Name)
	end)

	for idx, plr in ipairs(otherPlayers) do
		local rowBtn = Instance.new("TextButton")
		rowBtn.Name = "Player_" .. plr.Name
		rowBtn.LayoutOrder = idx
		rowBtn.Size = UDim2.new(1, -10, 0, 32)
		rowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
		rowBtn.Font = Enum.Font.GothamSemibold
		rowBtn.TextSize = 13
		rowBtn.BorderSizePixel = 0
		rowBtn.ZIndex = 12
		rowBtn.Parent = scroll
		Instance.new("UICorner", rowBtn).CornerRadius = UDim.new(0, 6)
		refreshRowVisual(rowBtn, plr.Name)

		trackConn(rowBtn.MouseButton1Click:Connect(function()
			selectedPlayerNames[plr.Name] = not selectedPlayerNames[plr.Name] or nil
			refreshRowVisual(rowBtn, plr.Name)
		end))
	end

	scroll.CanvasSize = UDim2.new(0, 0, 0, math.max(0, #otherPlayers * 36 + 4))

	local confirmBtn = Instance.new("TextButton")
	confirmBtn.Name = "ConfirmTargetsButton"
	confirmBtn.Size = UDim2.new(1, -16, 0, 36)
	confirmBtn.Position = UDim2.new(0, 8, 1, -42)
	confirmBtn.BackgroundColor3 = Color3.fromRGB(35, 125, 225)
	confirmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	confirmBtn.Font = Enum.Font.GothamBold
	confirmBtn.TextSize = 14
	confirmBtn.Text = "Confirm Targets"
	confirmBtn.BorderSizePixel = 0
	confirmBtn.ZIndex = 12
	confirmBtn.Parent = panel
	Instance.new("UICorner", confirmBtn).CornerRadius = UDim.new(0, 8)

	trackConn(confirmBtn.MouseButton1Click:Connect(function()
		if pickerFrame and pickerFrame.Parent then
			pickerFrame:Destroy()
			pickerFrame = nil
		end
	end))

	pickerFrame = panel
end

local function updateModeButtonText()
	if modeBtn then
		modeBtn.Text = "^ (" .. getCurrentTargetMode() .. ")"
	end
end

-- "Hold to Fire" GUI + "^" Target Mode Button + Auto-Fire ON/OFF Button
local function destroyFireGui()
	closeSubGuis()
	if fireGui and fireGui.Parent then
		fireGui:Destroy()
	end
	fireGui = nil
	holdBtn = nil
	modeBtn = nil
	autoFireBtn = nil
end

local function createFireGui()
	destroyFireGui()

	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "PhalanxHoldToFireGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 999
	screenGui.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "HoldToFireButton"
	btn.Size = UDim2.new(0, 175, 0, 56)
	btn.Position = UDim2.new(0.5, -135, 0.76, 0)
	btn.BackgroundColor3 = Color3.fromRGB(190, 40, 40)
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 16
	btn.Text = "Hold to Fire"
	btn.BorderSizePixel = 0
	btn.Active = true
	btn.Parent = screenGui
	Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 10)

	local arrowBtn = Instance.new("TextButton")
	arrowBtn.Name = "TargetModeButton"
	arrowBtn.Size = UDim2.new(0, 86, 0, 56)
	arrowBtn.Position = UDim2.new(0.5, 48, 0.76, 0)
	arrowBtn.BackgroundColor3 = Color3.fromRGB(45, 50, 60)
	arrowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	arrowBtn.Font = Enum.Font.GothamBold
	arrowBtn.TextSize = 13
	arrowBtn.Text = "^ (" .. getCurrentTargetMode() .. ")"
	arrowBtn.BorderSizePixel = 0
	arrowBtn.Active = true
	arrowBtn.Parent = screenGui
	Instance.new("UICorner", arrowBtn).CornerRadius = UDim.new(0, 10)

	local toggleAutoBtn = Instance.new("TextButton")
	toggleAutoBtn.Name = "AutoFireToggleButton"
	toggleAutoBtn.Size = UDim2.new(0, 110, 0, 38)
	toggleAutoBtn.Position = UDim2.new(0.5, -55, 0.76, -46)
	toggleAutoBtn.BackgroundColor3 = Color3.fromRGB(65, 70, 80)
	toggleAutoBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	toggleAutoBtn.Font = Enum.Font.GothamBold
	toggleAutoBtn.TextSize = 13
	toggleAutoBtn.Text = "Auto: OFF"
	toggleAutoBtn.BorderSizePixel = 0
	toggleAutoBtn.Active = true
	toggleAutoBtn.Parent = screenGui
	Instance.new("UICorner", toggleAutoBtn).CornerRadius = UDim.new(0, 8)

	trackConn(toggleAutoBtn.MouseButton1Click:Connect(function()
		autoFireEnabled = not autoFireEnabled
		holdingFire = autoFireEnabled
		refreshFireButtonVisuals()
	end))

	trackConn(arrowBtn.MouseButton1Click:Connect(function()
		targetModeIndex = (targetModeIndex % #TARGET_MODES) + 1
		local mode = getCurrentTargetMode()
		if mode == "RANDOM" then
			activeRandomTargetPlr = pickRandomPlayer()
			lastRandomSwitchTime = os.clock()
		elseif mode == "AIM" then
			table.clear(aimHitPlayerNames)
		end
		updateModeButtonText()
		if mode == "PLAYER" then
			openPlayerPickerGui()
		elseif mode == "AURA" then
			openAuraStudGui()
		else
			closeSubGuis()
		end
	end))

	trackConn(btn.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			holdingFire = true
			refreshFireButtonVisuals()
		end
	end))

	trackConn(btn.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			holdingFire = autoFireEnabled
			refreshFireButtonVisuals()
		end
	end))

	trackConn(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			holdingFire = autoFireEnabled
			refreshFireButtonVisuals()
		end
	end))

	fireGui = screenGui
	holdBtn = btn
	modeBtn = arrowBtn
	autoFireBtn = toggleAutoBtn
	refreshFireButtonVisuals()
end

-- Give "Phalanx ciws" Tool
local function givePhalanxTool()
	local backpack = LocalPlayer:WaitForChild("Backpack")
	local char = getChar()

	for _, container in ipairs({ backpack, char }) do
		if container then
			local existing = container:FindFirstChild(TOOL_NAME)
			if existing and existing:IsA("Tool") then
				existing:Destroy()
			end
		end
	end

	local tool = Instance.new("Tool")
	tool.Name = TOOL_NAME
	tool.RequiresHandle = true
	tool.CanBeDropped = false

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(1, 1, 1)
	handle.Transparency = 1
	handle.CanCollide = false
	handle.Massless = true
	handle.Parent = tool

	tool.Equipped:Connect(function()
		equipped = true
		holdingFire = autoFireEnabled
		setClientCharacterInvisible(true)

		local hum = getHumanoid()
		if hum then
			hum.Sit = true
		end

		local root = getRoot()
		local startPos = root and root.Position or Vector3.new(0, 10, 0)
		local look = root and root.CFrame.LookVector or Vector3.new(0, 0, -1)
		local startYaw = math.atan2(-look.X, -look.Z)

		createTurret(startPos, startYaw)
		createFireGui()
	end)

	tool.Unequipped:Connect(function()
		equipped = false
		holdingFire = false
		autoFireEnabled = false
		setClientCharacterInvisible(false)
		clearConnections()
		destroyFireGui()
		destroyTurret()

		local hum = getHumanoid()
		if hum then
			hum.Sit = false
		end
	end)

	tool.Parent = backpack
end

RunService.RenderStepped:Connect(function(dt)
	if not equipped then
		return
	end
	updateTurret(dt)
end)

task.spawn(function()
	while true do
		if equipped then
			local shouldFire = holdingFire or (autoFireEnabled and getCurrentTargetMode() == "AURA" and #getAuraPlayers() > 0)
			if shouldFire then
				triggerSlapRemote()
			end
		end
		task.wait(LOOP_DELAY)
	end
end)

givePhalanxTool()
LocalPlayer.CharacterAdded:Connect(function()
	equipped = false
	holdingFire = false
	autoFireEnabled = false
	table.clear(savedVisibility)
	clearConnections()
	destroyFireGui()
	destroyTurret()
	task.wait(0.25)
	givePhalanxTool()
end)
