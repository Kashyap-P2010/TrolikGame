--[[
	ExamSystem/init.server.luau
	
	Responsibilities:
	  • Fetch question pools from GitHub (private repo) on startup + every 5 minutes.
	  • Serve 20-question exam sets to clients via GetExamQuestions RemoteFunction.
	  • Fall back to hardcoded questions if the network fetch fails for any reason.
	
	Question distribution per exam difficulty:
	  Easy   → 4 easy  | 5 medium | 6 hard  | 4 extreme | 1 impossible  (total 20)
	  Medium → 3 easy  | 3 medium | 6 hard  | 4 extreme | 4 impossible  (total 20)
	  Hard   → 1 easy  | 2 medium | 3 hard  | 6 extreme | 8 impossible  (total 20)
]]

local HttpService = game:GetService("HttpService")
local Players     = game:GetService("Players")

local Shared      = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ExamRemotes = require(Shared:WaitForChild("ExamRemotes"))

-- Secrets (gitignored — user must fill in PAT)
local ok, SecretsOrErr = pcall(function()
	return require(script:FindFirstChild("ExamSecrets"))
end)
local GITHUB_PAT: string = (ok and type(SecretsOrErr) == "table" and SecretsOrErr.GITHUB_PAT) or ""

if GITHUB_PAT == "" or GITHUB_PAT == "PASTE_YOUR_GITHUB_PAT_HERE" then
	warn("[ExamSystem] ⚠ GITHUB_PAT is not set in ExamSecrets.luau — will use fallback questions only.")
end

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------
local REFRESH_INTERVAL = 300   -- re-fetch every 5 minutes
local GITHUB_REPO      = "Kashyap-P2010/TrolikGame"
local GITHUB_BRANCH    = "master"

local DIFF_FILES = {
	easy       = "Questions/easy.json",
	medium     = "Questions/medium.json",
	hard       = "Questions/hard.json",
	extreme    = "Questions/extreme.json",
	impossible = "Questions/impossible.json",
}

-- How many to pull from each pool per exam level
local EXAM_DISTRIBUTION = {
	Easy   = { easy=4, medium=5, hard=6,  extreme=4, impossible=1 },
	Medium = { easy=3, medium=3, hard=6,  extreme=4, impossible=4 },
	Hard   = { easy=1, medium=2, hard=3,  extreme=6, impossible=8 },
}

---------------------------------------------------------------------------
-- Hardcoded fallback questions (used if GitHub fetch fails)
-- Enough to cover the hardest distribution (Hard: 1+2+3+6+8=20)
-- 15 per difficulty for safety headroom.
---------------------------------------------------------------------------
local FALLBACK: { [string]: { {q:string,a:string,b:string,c:string,correct:string} } } = {
	easy = {
		{q="Which planet is closest to the Sun?",          a="Earth",       b="Mercury",         c="Mars",        correct="B"},
		{q="How many days are in a week?",                  a="5",           b="10",              c="7",           correct="C"},
		{q="What is the capital of Poland?",                a="Krakow",      b="Warsaw",          c="Gdansk",      correct="B"},
		{q="How many legs does a dog have?",                a="4",           b="2",               c="6",           correct="A"},
		{q="What color is made by mixing blue and yellow?", a="Green",       b="Red",             c="Purple",      correct="A"},
		{q="Which is the largest ocean?",                   a="Atlantic",    b="Pacific",         c="Indian",      correct="B"},
		{q="What is 5 + 5?",                                a="10",          b="15",              c="20",          correct="A"},
		{q="What is the largest mammal?",                   a="Elephant",    b="Giraffe",         c="Blue whale",  correct="C"},
		{q="How many planets are in the Solar System?",     a="7",           b="8",               c="9",           correct="B"},
		{q="Which animal says meow?",                       a="Dog",         b="Rabbit",          c="Cat",         correct="C"},
		{q="What is the official language of Poland?",      a="English",     b="Polish",          c="German",      correct="B"},
		{q="Which season comes after summer?",              a="Autumn",      b="Winter",          c="Spring",      correct="A"},
		{q="How many minutes are in an hour?",              a="30",          b="60",              c="100",         correct="B"},
		{q="What is the capital of France?",                a="Berlin",      b="Madrid",          c="Paris",       correct="C"},
		{q="How many hours are in a day?",                  a="12",          b="24",              c="48",          correct="B"},
	},
	medium = {
		{q="What is the chemical symbol for gold?",          a="Go",          b="Au",              c="Ag",          correct="B"},
		{q="In what year did World War II end?",             a="1943",        b="1944",            c="1945",        correct="C"},
		{q="How many bones are in the adult human body?",   a="186",         b="206",             c="226",         correct="B"},
		{q="What is the speed of light in km/s?",           a="100,000",     b="200,000",         c="300,000",     correct="C"},
		{q="Who wrote Romeo and Juliet?",                   a="Shakespeare", b="Dickens",         c="Austen",      correct="A"},
		{q="What is the chemical formula for water?",       a="H2O2",        b="H2O",             c="HO2",         correct="B"},
		{q="What is the largest planet in Solar System?",   a="Saturn",      b="Neptune",         c="Jupiter",     correct="C"},
		{q="How many chambers does a human heart have?",    a="2",           b="3",               c="4",           correct="C"},
		{q="What is the capital of Australia?",             a="Sydney",      b="Canberra",        c="Melbourne",   correct="B"},
		{q="Which element has atomic number 1?",            a="Helium",      b="Oxygen",          c="Hydrogen",    correct="C"},
		{q="How many continents are on Earth?",             a="5",           b="6",               c="7",           correct="C"},
		{q="What is the hardest natural substance?",        a="Diamond",     b="Quartz",          c="Iron",        correct="A"},
		{q="Who painted the Mona Lisa?",                    a="Michelangelo",b="Leonardo da Vinci",c="Raphael",    correct="B"},
		{q="Which ocean is the deepest?",                   a="Atlantic",    b="Pacific",         c="Indian",      correct="B"},
		{q="What is the currency of Japan?",                a="Yuan",        b="Won",             c="Yen",         correct="C"},
	},
	hard = {
		{q="What is the powerhouse of the cell?",              a="Nucleus",      b="Mitochondria",   c="Ribosome",    correct="B"},
		{q="What is the Pythagorean theorem?",                 a="a+b=c",        b="a²+b²=c²",       c="a-b=c²",      correct="B"},
		{q="What is the chemical symbol for iron?",            a="Ir",           b="In",             c="Fe",          correct="C"},
		{q="What does DNA stand for?",                         a="Deoxyribonucleic Acid",b="Double Nucleic Acid",c="Dioxynuclear Acid", correct="A"},
		{q="Who developed the theory of relativity?",          a="Newton",       b="Einstein",       c="Bohr",        correct="B"},
		{q="What is the boiling point of water at sea level?", a="90°C",         b="100°C",          c="110°C",       correct="B"},
		{q="Which gas do plants absorb for photosynthesis?",   a="Oxygen",       b="Nitrogen",       c="Carbon dioxide", correct="C"},
		{q="What is osmosis?",                                 a="Active transport of solutes", b="Diffusion of water through a semipermeable membrane", c="Movement of ions", correct="B"},
		{q="How many elements are in the periodic table?",     a="108",          b="118",            c="128",         correct="B"},
		{q="What is the chemical formula for table salt?",     a="NaCl",         b="KCl",            c="MgCl",        correct="A"},
		{q="What is the speed of sound in air at 20°C?",       a="250 m/s",      b="343 m/s",        c="500 m/s",     correct="B"},
		{q="Which law states that pressure times volume is constant?", a="Boyle's Law", b="Charles's Law", c="Newton's Law", correct="A"},
		{q="What is the main component of natural gas?",       a="Propane",      b="Ethane",         c="Methane",     correct="C"},
		{q="What is the atomic number of carbon?",             a="4",            b="6",              c="8",           correct="B"},
		{q="Who discovered penicillin?",                       a="Marie Curie",  b="Louis Pasteur",  c="Alexander Fleming", correct="C"},
	},
	extreme = {
		{q="What does 'aphelion' mean in astronomy?",          a="Greatest distance from Sun",b="Highest speed of a planet",c="Where orbits intersect", correct="A"},
		{q="Which element has the highest melting point?",     a="Osmium",       b="Tungsten",       c="Rhenium",     correct="B"},
		{q="What is the SI unit of luminous intensity?",        a="Candela",      b="Lumen",          c="Lux",         correct="A"},
		{q="Which gas makes up most of Titan's atmosphere?",   a="Methane",      b="Nitrogen",       c="Carbon dioxide", correct="B"},
		{q="What does 'exclave' mean?",                        a="A separated part of a country",b="A landlocked country",c="An autonomous region", correct="A"},
		{q="What does 'albedo' measure?",                      a="Surface ability to reflect radiation",b="Amount of oxygen",c="Density of a planet", correct="A"},
		{q="What does 'isobar' mean in meteorology?",          a="Line of equal pressure",b="Line of equal temperature",c="Line of equal humidity", correct="A"},
		{q="Which mineral is hardest after diamond?",          a="Topaz",        b="Corundum",       c="Garnet",       correct="B"},
		{q="What does 'isotope' mean?",                        a="Atoms of same element, different neutrons",b="Atoms with same mass",c="Molecules with different electrons", correct="A"},
		{q="Which language belongs to the Dravidian family?",  a="Hindi",        b="Tamil",          c="Bengali",     correct="B"},
		{q="What is dolomite composed of?",                    a="Calcium only", b="Silica",         c="Ca and Mg carbonate", correct="C"},
		{q="Who discovered Triton, Neptune's moon?",           a="Edmond Halley",b="William Lassell",c="Tycho Brahe", correct="B"},
		{q="Where is the Mariana Trench?",                     a="Atlantic",     b="Indian",         c="Pacific",     correct="C"},
		{q="What is dynamic viscosity measured in?",           a="Pascal-seconds",b="Newtons",       c="Lux",         correct="A"},
		{q="What does the Coriolis effect cause?",             a="Tides",        b="Deflection of winds",c="Seasons",  correct="B"},
	},
	impossible = {
		{q="Where does the name 'atlas' for map collections come from?", a="Mercator's Atlas",b="Atlas Mountains",c="Greek city Atla", correct="A"},
		{q="Why does quartz glass withstand higher temperatures?",       a="More sodium",      b="Fewer impurities",c="Ceramic coating", correct="B"},
		{q="Who gave the name to the astronomy unit 'mors'?",            a="Johannes Kepler",  b="Urbain Le Verrier",c="No such unit exists", correct="C"},
		{q="Why is tungsten used in filaments?",                         a="It is light",      b="Very high melting point",c="No electrical conduction", correct="B"},
		{q="Why do fireflies glow?",                                     a="Fluorescence",     b="Phosphorescence", c="Bioluminescence", correct="C"},
		{q="Where does the word 'algorithm' come from?",                 a="Al-Khwarizmi",     b="Archimedes",      c="Aristotle",       correct="A"},
		{q="What is dynamic viscosity measured in?",                     a="Pascal-seconds",   b="Newtons",         c="Lux",             correct="A"},
		{q="Why is platinum valued in catalysts?",                       a="Lightest metal",   b="Speeds up chemical reactions",c="No heat conduction", correct="B"},
		{q="What phenomenon describes redshift in galaxies?",            a="Doppler effect",   b="Heisenberg principle",c="Hubble's law",  correct="C"},
		{q="What is the Chandrasekhar limit?",                           a="Max mass of a white dwarf",b="Min mass of black hole",c="Speed of a pulsar", correct="A"},
		{q="What is quorum sensing in bacteria?",                        a="Chemical communication",b="Gene mutation",c="Spore formation", correct="A"},
		{q="What does 'apoptosis' mean?",                                a="Cell growth",      b="Programmed cell death",c="Cell division",  correct="B"},
		{q="What is a Lagrange point?",                                  a="Point of gravitational equilibrium",b="Midpoint of galaxy",c="Orbit crossing point", correct="A"},
		{q="What is the Mpemba effect?",                                 a="Hot water may freeze faster than cold",b="Cold water boils faster",c="Ice melts slower at altitude", correct="A"},
		{q="What is topological quantum computing?",                     a="Computing using topology of space",b="Quantum bits on surface",c="Using anyons as qubits", correct="C"},
	},
}

---------------------------------------------------------------------------
-- Live question cache (filled by GitHub fetches)
---------------------------------------------------------------------------
type Question = {q: string, a: string, b: string, c: string, correct: string}
local questionPools: { [string]: {Question} } = {}
local poolReady = false

---------------------------------------------------------------------------
-- Utilities
---------------------------------------------------------------------------
local function shuffleTable<T>(t: {T}): {T}
	local n = #t
	for i = n, 2, -1 do
		local j = math.random(1, i)
		t[i], t[j] = t[j], t[i]
	end
	return t
end

--- Safely pick `count` random entries from `pool`. If pool too small, use all & warn.
local function pickRandom(pool: {Question}, count: number, label: string): {Question}
	if #pool == 0 then
		warn("[ExamSystem] Pool for '" .. label .. "' is EMPTY — returning empty slice")
		return {}
	end
	if count > #pool then
		warn(string.format("[ExamSystem] Pool '%s' has %d questions but %d requested — using all", label, #pool, count))
		count = #pool
	end
	local copy = table.clone(pool)
	shuffleTable(copy)
	local out = {}
	for i = 1, count do
		out[i] = copy[i]
	end
	return out
end

--- Get the active pool for a difficulty key, falling back to hardcoded table.
local function getPool(key: string): {Question}
	if questionPools[key] and #questionPools[key] > 0 then
		return questionPools[key]
	end
	warn("[ExamSystem] Using FALLBACK pool for '" .. key .. "'")
	return FALLBACK[key] or {}
end

---------------------------------------------------------------------------
-- GitHub fetch
---------------------------------------------------------------------------
local function fetchFile(filePath: string): string?
	if GITHUB_PAT == "" or GITHUB_PAT == "PASTE_YOUR_GITHUB_PAT_HERE" then
		return nil
	end
	local url = string.format(
		"https://api.github.com/repos/%s/contents/%s?ref=%s",
		GITHUB_REPO, filePath, GITHUB_BRANCH
	)
	local success, response = pcall(function()
		return HttpService:RequestAsync({
			Url    = url,
			Method = "GET",
			Headers = {
				["Authorization"] = "Bearer " .. GITHUB_PAT,
				["Accept"]        = "application/vnd.github.v3.raw",
				["User-Agent"]    = "TrolikGame-ExamSystem/1.0",
			},
		})
	end)
	if not success then
		warn("[ExamSystem] HTTP request failed for '" .. filePath .. "': " .. tostring(response))
		return nil
	end
	if not response.Success then
		warn(string.format("[ExamSystem] HTTP %d for '%s': %s", response.StatusCode, filePath, response.Body))
		return nil
	end
	return response.Body
end

local function parseJSON(raw: string, label: string): {Question}?
	local ok2, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok2 then
		warn("[ExamSystem] JSON parse failed for '" .. label .. "': " .. tostring(decoded))
		return nil
	end
	if type(decoded) ~= "table" then
		warn("[ExamSystem] Expected JSON array for '" .. label .. "', got " .. type(decoded))
		return nil
	end
	-- Validate each entry
	local out: {Question} = {}
	for idx, entry in decoded do
		if type(entry) ~= "table" then continue end
		if type(entry.q) == "string" and type(entry.a) == "string"
			and type(entry.b) == "string" and type(entry.c) == "string"
			and type(entry.correct) == "string" then
			table.insert(out, {
				q       = entry.q,
				a       = entry.a,
				b       = entry.b,
				c       = entry.c,
				correct = entry.correct,
			})
		else
			warn(string.format("[ExamSystem] Malformed question #%d in '%s' — skipping", idx, label))
		end
	end
	print(string.format("[ExamSystem] Fetched %d valid questions from '%s'", #out, label))
	return out
end

local function fetchAllPools()
	print("[ExamSystem] Fetching question pools from GitHub...")
	local anySuccess = false
	for key, filePath in DIFF_FILES do
		local raw = fetchFile(filePath)
		if raw then
			local parsed = parseJSON(raw, key)
			if parsed and #parsed > 0 then
				questionPools[key] = parsed
				anySuccess = true
			end
		end
	end
	if anySuccess then
		poolReady = true
		print("[ExamSystem] Question pools updated from GitHub ✓")
	else
		warn("[ExamSystem] All GitHub fetches failed — using fallback questions")
		-- Initialize pools from fallback so they're available
		for key, pool in FALLBACK do
			if not questionPools[key] or #questionPools[key] == 0 then
				questionPools[key] = pool
			end
		end
		poolReady = true
	end
end

---------------------------------------------------------------------------
-- Build exam question set for a given exam difficulty level
---------------------------------------------------------------------------
local function buildExamSet(examLevel: string): {Question}
	local dist = EXAM_DISTRIBUTION[examLevel]
	if not dist then
		warn("[ExamSystem] Unknown exam level: '" .. tostring(examLevel) .. "' — defaulting to Easy")
		dist = EXAM_DISTRIBUTION.Easy
	end

	local sections: { {Question} } = {}
	for poolKey, count in dist do
		local slice = pickRandom(getPool(poolKey), count, poolKey)
		for _, q in slice do
			table.insert(sections, q)
		end
	end

	-- Shuffle the combined set so difficulties are interleaved randomly
	shuffleTable(sections)
	return sections
end

---------------------------------------------------------------------------
-- ExamRemotes setup
---------------------------------------------------------------------------
ExamRemotes.setup()

local getExamQuestions = ExamRemotes.get("GetExamQuestions") :: RemoteFunction
local saveExamResult   = ExamRemotes.get("SaveExamResult")   :: RemoteEvent

--- RemoteFunction: client calls this to receive their 20-question exam set.
getExamQuestions.OnServerInvoke = function(player: Player): {Question}
	-- Determine exam difficulty from player attribute (set by lobby/teleport)
	local difficulty = player:GetAttribute("ExamDifficulty")
	if type(difficulty) ~= "string" or not EXAM_DISTRIBUTION[difficulty] then
		difficulty = "Easy"
		warn(string.format("[ExamSystem] Player '%s' has no/invalid ExamDifficulty attr — defaulting to Easy", player.Name))
	end

	if not poolReady then
		warn("[ExamSystem] Pools not ready yet — using fallback immediately for " .. player.Name)
		-- Pre-fill fallback
		for key, pool in FALLBACK do
			if not questionPools[key] or #questionPools[key] == 0 then
				questionPools[key] = pool
			end
		end
		poolReady = true
	end

	local questions = buildExamSet(difficulty)
	print(string.format("[ExamSystem] Serving %d questions (%s) to %s", #questions, difficulty, player.Name))
	return questions
end

--- RemoteEvent: client reports final score → server saves, awards coins, tracks exams.
saveExamResult.OnServerEvent:Connect(function(player: Player, score: number, total: number)
	-- Validate inputs (never trust the client)
	if type(score) ~= "number" or type(total) ~= "number" then
		warn("[ExamSystem] Invalid SaveExamResult args from " .. player.Name)
		return
	end
	score = math.clamp(math.round(score), 0, total)
	total = math.max(1, math.round(total))  -- avoid div/0

	local percentage = math.round((score / total) * 100)
	player:SetAttribute("ExamLastScore",  score)
	player:SetAttribute("ExamLastTotal",  total)
	player:SetAttribute("ExamPercentage", percentage)

	print(string.format("[ExamSystem] %s scored %d/%d (%d%%)", player.Name, score, total, percentage))

	-- Award coins: 10 per correct answer
	local COINS_PER_CORRECT = 10
	local coinsEarned = score * COINS_PER_CORRECT
	
	-- Safely require PlayerData (may not be loaded yet in edge cases)
	local PlayerData
	local ok, err = pcall(function()
		PlayerData = require(game:GetService("ServerScriptService"):FindFirstChild("DataSystem"):FindFirstChild("PlayerData"))
	end)
	
	if ok and PlayerData and PlayerData.hasSession(player) then
		-- Award coins
		if coinsEarned > 0 then
			PlayerData.addCoins(player, coinsEarned)
		end
		
		-- Track exam taken
		PlayerData.incrementExamsTaken(player)
		
		-- Check if passed (70% threshold)
		if percentage >= 70 then
			PlayerData.incrementExamsPassed(player)
			print(string.format("[ExamSystem] %s PASSED the exam! (%d%%)", player.Name, percentage))
		end
		
		-- Update best score
		PlayerData.updateBestScore(player, percentage)
	else
		warn("[ExamSystem] Could not access PlayerData for " .. player.Name .. " — coins not awarded: " .. tostring(err))
	end
end)

---------------------------------------------------------------------------
-- Startup: initial fetch + periodic refresh
---------------------------------------------------------------------------

-- Pre-fill pools with fallback immediately so server is never empty
for key, pool in FALLBACK do
	questionPools[key] = pool
end
poolReady = true

-- Fetch live questions in background (non-blocking)
task.spawn(function()
	fetchAllPools()
	-- Refresh every REFRESH_INTERVAL seconds
	while true do
		task.wait(REFRESH_INTERVAL)
		fetchAllPools()
	end
end)

print("[ExamSystem] Initialized ✓ — PAT " .. (GITHUB_PAT ~= "" and GITHUB_PAT ~= "PASTE_YOUR_GITHUB_PAT_HERE" and "set ✓" or "NOT set — fallback only"))
