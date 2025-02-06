local Constants = {
	Commands = {
		Help = "help",
		Options = "options",
		Start = "start",
		Stop = "stop",
		Status = "status",
		Reset = "reset"
	},

	Events = {
		TradeShow = "TRADE_SHOW",
		PlayerTargetChanged = "PLAYER_TARGET_CHANGED",
	},

	GlobalEvents = {
		PlayerLogin = "PLAYER_LOGIN",
	},

	OptionDefaults = {
		verbose = false,
		maxTries = 25,
	},

	TradeRangeIndex = 2,

	AddonName = "LegacyTradeHelper",
	AddonAbbreviation = "lth",

	AttemptIntervalInitial = 0.1,
	AttemptIntervalMin = 1.0,
	AttemptIntervalMax = 3.0,
}

-- *****************************
-- ********** Classes **********
-- *****************************
-- Class Printer
local Printer = {
	indent = "",
	enabled = true,
}
Printer.__index = Printer

function Printer:new(printer)
	local newPrinter = {}
	setmetatable(newPrinter, Printer)

	if printer ~= nil and type(printer) == "table" and printer.indent ~= nil then
		newPrinter.indent = printer.indent
	end

	return newPrinter
end

function Printer:Print(msg)
	if self.enabled then
		print(self.indent .. tostring(msg))
	end
end

function Printer:AddonPrint(msg)
	if self.enabled then
		print(Constants.AddonName .. ": " .. msg)
	end
end

function Printer:StartIndent()
	self.indent = self.indent .. string.rep(" ", 2)
end

function Printer:EndIndent()
	if #self.indent >= 2 then
		self.indent = string.rep(" ", #self.indent - 2)
	end
end

function Printer:SetEnabled(isEnabled)
	isEnabled = (isEnabled == nil) and true or isEnabled
	self.enabled = isEnabled
end
-- END Class Printer

-- Class Status
local Status = {
	isRunning = true,
	triesRemaining = 0,
	targetGUID = "",
	targetName = "",
}
Status.__index = Status

function Status:new(maxTries)
	local newStatus = {}
	setmetatable(newStatus, Status)

	newStatus.targetGUID = UnitGUID("target")
	newStatus.targetName = UnitName("target")
	newStatus.triesRemaining = maxTries

	return newStatus
end
-- END Class Status

-- Class Option
local OptionValidator = {
	Boolean = function(currentValue, s)
		if string.lower(s) == "true" then
			return true, nil
		elseif string.lower(s) == "false" then
			return false, nil
		else
			return currentValue, "Not a valid boolean."
		end
	end,
	Number = function(currentValue, s)
		local numberValue = tonumber(s)
		if numberValue ~= nil then
			return numberValue, nil
		else
			return currentValue, "Not a valid number."
		end
	end,
}

local Option = {
	value = nil,
	validator = nil,
}
Option.__index = Option

function Option:new(value, validator)
	local newOption = {}
	setmetatable(newOption, Option)
	newOption.value = value
	newOption.validator = validator
	return newOption
end

function Option:FromString(s)
	if self.validator == nil then
		self.value = s
		return true
	end

	local newValue, result = self.validator(self.value, s)
	if result == nil then self.value = newValue end

	return result
end
-- END Class Option

-- Class CommandEntry
local CommandEntry = {
	exec = nil,
	help = nil,
}
CommandEntry.__index = CommandEntry

function CommandEntry:new(execFunction, helpFunction)
	local newEntry = {}
	setmetatable(newEntry, CommandEntry)

	newEntry.exec = execFunction
	newEntry.help = helpFunction

	return newEntry
end

function CommandEntry:Execute(args)
	if self.exec ~= nil then
		return self.exec(args)
	end

	return nil
end

function CommandEntry:PrintHelpText(commandName, printer)
	if self.help ~= nil then
		return self.help(commandName, printer)
	end

	return nil
end
-- End Class CommandEntry

-- *******************************
-- ********** Variables **********
-- *******************************
local tradeResponseFrame = CreateFrame("Frame")
local currentStatus = nil
local options = {}
local commandTable = {}

-- *******************************
-- ********** Functions **********
-- *******************************
local function clamp(x, min, max)
    if x < min then return min end
    if x > max then return max end
    return x
end

local function RandomFloat(rangeStart, rangeEnd, decimals)
	rangeStart = rangeStart and abs(rangeStart) or 0
	rangeEnd = rangeEnd and abs(rangeEnd) or 1
	decimals = decimals and clamp(decimals, 0, 10) or 2

	local spread = rangeEnd - rangeStart
	local value = rangeStart + math.random() * spread

	return tonumber(string.format("%."..decimals.."f", value))
end

local function CreateDefaultOptions()
	return {
		verbose = Option:new(Constants.OptionDefaults.verbose, OptionValidator.Boolean),
		maxTries = Option:new(Constants.OptionDefaults.maxTries, OptionValidator.Number),
	}
end

local function LoadOptions()
	local printer = Printer:new()
	printer:AddonPrint("Loading stored options...");
	printer:StartIndent()

	if LegacyTradeHelperSettings == nil or LegacyTradeHelperSettings.Options == nil then
		printer:AddonPrint("There was an issue loading options, please try the reset command. See help for details.")
	else
		local storedOptions = LegacyTradeHelperSettings.Options
		for k,v in pairs(storedOptions) do
			local realOption = options[k]
			if realOption == nil then
				storedOptions[k] = nil
				printer:Print("Stored option "..k.." is not a valid option and was removed.")
			else
				local result = realOption:FromString(tostring(v))
				if result ~= nil then
					storedOptions[k] = nil
					printer:Print("Stored value for option "..k.." is invalid and was removed.")
				end
			end
		end
	end

	printer:Print("Option load complete.")
end

local function StoreOptions()
	LegacyTradeHelperSettings = {
		Options = {},
	}

	for k,v in pairs(options) do
		LegacyTradeHelperSettings.Options[k] = v.value
	end
end

local function StartHelper(tickFunction)
	for _,event in pairs(Constants.Events) do
		tradeResponseFrame:RegisterEvent(event)
	end

	currentStatus = Status:new(options.maxTries.value)
	local nextInterval = RandomFloat(Constants.AttemptIntervalMin, Constants.AttemptIntervalMax, 1)
	C_Timer.After(Constants.AttemptIntervalInitial, tickFunction)
end

local function StopHelper()
	for _,event in pairs(Constants.Events) do
		tradeResponseFrame:UnregisterEvent(event)
	end

	currentStatus = nil
end

local function AttemptTrade()
	if currentStatus == nil then return end
	if UnitGUID("target") ~= currentStatus.targetGUID then return end

	local printer = Printer:new()

	currentStatus.triesRemaining = currentStatus.triesRemaining - 1
	if currentStatus.triesRemaining <= 0 then
		printer:Print("Maximum number of attempts reached, helper will stop. Use start to try again.")
		StopHelper()
		return
	end

	printer:SetEnabled(options.verbose.value)
	printer:AddonPrint("** AttemptTrade Tick **")
	printer:StartIndent()

	InitiateTrade("target")

	local nextInterval = RandomFloat(Constants.AttemptIntervalMin, Constants.AttemptIntervalMax, 1)
	printer:Print("Trade request attempted. There will be " .. currentStatus.triesRemaining .. " more attempt(s) with the next happening in " .. nextInterval .. " seconds.")
	C_Timer.After(nextInterval, AttemptTrade)
end

local function CommandHelp(args, badCommand)
	local printer = Printer:new()
	printer:AddonPrint(" Help")
	printer:StartIndent()

	if badCommand ~= nil then
		printer:Print("Command, " .. badCommand .. ", not recognized.")
	end

	printer:Print("Usage:")
	printer:StartIndent()
	for commandName,commandEntry in pairs(commandTable) do
		if commandEntry.help ~= nil then
			commandEntry:PrintHelpText(commandName, Printer:new(printer))
		end
	end
end

local function CommandHelpHelp(commandName, printer)
	printer:Print("* "..commandName)
	printer:StartIndent()
	printer:Print("Shows usage for "..Constants.AddonName..".")
end

local function CommandOptions(args)
	local printer = Printer:new()
	printer:AddonPrint("Options")
	printer:StartIndent()
	
	local optionName = (args ~= nil and #args >= 1) and args[1] or nil
	local valueString = (args ~= nil and #args >= 2) and args[2] or nil

	if optionName == nil then
		-- Print all options and values.
		for k,v in pairs(options) do
			printer:Print(k .. " = " .. tostring(v.value))
		end
	else
		local targetOption = options[optionName]
		if targetOption == nil then
			printer:Print("Specified option, "..optionName..", does not exist.")
		elseif valueString == nil then
			printer:Print(optionName .. " = " .. tostring(targetOption.value))
		else
			local response = targetOption:FromString(valueString)
			if response ~= nil then
				printer:Print("Could not set the value of option, "..optionName..".")
				printer:StartIndent()
				printer:Print("Reason: "..tostring(response))
				printer:EndIndent()
			else
				printer:Print(optionName .. " = " .. tostring(targetOption.value))
				StoreOptions()
			end
		end
	end
end

local function CommandOptionsHelp(commandName, printer)
	printer:Print("* "..commandName.." [option] [value]")
	printer:StartIndent()
	printer:Print("Displays or changes the value of options.")
	printer:Print("[option] - Optional. If included, shows the value for the specified option.")
	printer:Print("[value] - Optional. If included, sets the value for the specified option.")
end

local function CommandStart(args)
	local printer = Printer:new()
	printer:AddonPrint("Start")
	printer:StartIndent()

	if currentStatus ~= nil and currentStatus.isRunning then
		printer:Print("Helper is already running. Use status command for details.")
		return
	end

	if UnitGUID("target") == nil then
		printer:Print("Helper not starting, no target selected.")
		return
	end

	if UnitGUID("target") == UnitGUID("player") then
		printer:Print("Helper not starting, cannot trade with yourself.")
		return
	end

	if not UnitPlayerControlled("target") then
		printer:Print("Helper not starting, target is not a player.")
		return
	end

	if not CheckInteractDistance("target", Constants.TradeRangeIndex) then
		printer:Print("Helper not starting, target is too far away.")
		return
	end

	StartHelper(AttemptTrade)

	printer:Print("Helper has started, use the status command for details.")
	printer:Print("Changing targets will automatically stop the helper. Use the stop command to stop it manually.")
end

local function CommandStartHelp(commandName, printer)
	printer:Print("* "..commandName)
	printer:StartIndent()
	printer:Print("Starts the helper process.")
end

local function CommandStop(args)
	local printer = Printer:new()
	printer:AddonPrint("Stop")
	printer:StartIndent()

	StopHelper()

	printer:Print("Helper has been stopped.")
end

local function CommandStopHelp(commandName, printer)
	printer:Print("* "..commandName)
	printer:StartIndent()
	printer:Print("Stops the helper process.")
end

local function CommandStatus(args)
	local printer = Printer:new()
	printer:AddonPrint("Status")
	printer:StartIndent()
	if currentStatus ~= nil and currentStatus.isRunning then
		printer:Print(""
			.. "Helper is running. Currently trying to trade " .. currentStatus.targetName
			.. " with " .. currentStatus.triesRemaining .. " attempt(s) remaining."
		)
	else
		printer:Print("Not running.")
	end
end

local function CommandStatusHelp(commandName, printer)
	printer:Print("* "..commandName)
	printer:StartIndent()
	printer:Print("Displays the current status of the helper process.")
end

local function CommandReset(args)
	local printer = Printer:new()
	printer:AddonPrint("Reset")
	printer:StartIndent()

	LegacyTradeHelperSettings = nil
	options = CreateDefaultOptions()

	printer:Print("All settings restored to default.")
end

local function CommandResetHelp(commandName, printer)
	printer:Print("* "..commandName)
	printer:StartIndent()
	printer:Print("Resets all settings to default.")
end

-- **************************
-- ********** MAIN **********
-- **************************

options = CreateDefaultOptions()

commandTable = {
	[Constants.Commands.Help] = CommandEntry:new(CommandHelp, CommandHelpHelp),
	[Constants.Commands.Options] = CommandEntry:new(CommandOptions, CommandOptionsHelp),
	[Constants.Commands.Start] = CommandEntry:new(CommandStart, CommandStartHelp),
	[Constants.Commands.Stop] = CommandEntry:new(CommandStop, CommandStopHelp),
	[Constants.Commands.Status] = CommandEntry:new(CommandStatus, CommandStatusHelp),
	[Constants.Commands.Reset] = CommandEntry:new(CommandReset, CommandResetHelp),
}

SLASH_LEGACYTRADEHELPER1 = "/" .. Constants.AddonName
SLASH_LEGACYTRADEHELPER2 = "/" .. Constants.AddonAbbreviation
SlashCmdList["LEGACYTRADEHELPER"] = function(msg)
	local _, _, cmd, args = string.find(msg, "%s?(%w+)%s?(.*)")
	local args = args and { strsplit(" ", args) } or nil
	if args ~= nil and #args == 1 and args[1] == "" then args = nil end

	if cmd ~= nil then
		local command = commandTable[string.lower(cmd)]
		if command ~= nil then
			command:Execute(args)
		else
			CommandHelp(args, cmd)
		end
	else
		CommandHelp(args)
	end
end

local eventHandlers = {
	[Constants.GlobalEvents.PlayerLogin] = function(args)
		if LegacyTradeHelperSettings == nil then
			StoreOptions()
			Printer:new():AddonPrint("First time initialization complete.")
		else
			LoadOptions()
		end
	end,
	[Constants.Events.TradeShow] = function(args)
		if currentStatus == nil then return end

		local tradeTarget = currentStatus.targetName

		StopHelper()

		Printer:new():AddonPrint("Trade successfully opened with " .. tradeTarget ..", helper stopped.")
	end,
	[Constants.Events.PlayerTargetChanged] = function(args)
		if currentStatus == nil then return end
		StopHelper()

		Printer:new():AddonPrint("Target change detected, helper stopped.")
	end,
}

tradeResponseFrame:RegisterEvent(Constants.GlobalEvents.PlayerLogin)
tradeResponseFrame:SetScript(
	"OnEvent",
	function(self, event, ...)
		local args = {...}
		local handler = eventHandlers[event]
		if handler ~= nil then
			handler(args)
		else
			print("Unhandled event: " .. event)
		end
	end
)