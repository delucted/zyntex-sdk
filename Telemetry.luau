local Session = require(script.Parent:WaitForChild("api"))
local HttpService = game:GetService("HttpService")

local Telemetry = {}
Telemetry.__index = Telemetry

export type LabelSet = { [string]: string }

export type MetricOpts = {
	--[[
	Optional human-readable description
	]]
	description: string?,
	--[[
	Labels, used for filtering metrics on the dashboard
	]]
	labels: { string }?,
	--[[
	Only for Histogram
	]]
	buckets: { number }?,
}

export type CounterMetric = {
	inc: (self: CounterMetric, delta: number?, labels: LabelSet?) -> (),
}

export type GaugeMetric = {
	set: (self: GaugeMetric, value: number,  labels: LabelSet?) -> (),
	inc: (self: GaugeMetric, delta: number?, labels: LabelSet?) -> (),
	dec: (self: GaugeMetric, delta: number?, labels: LabelSet?) -> (),
}

export type HistogramMetric = {
	observe: (self: HistogramMetric, value: number, labels: LabelSet?) -> (),
}

export type SummaryMetric = {
	observe: (self: SummaryMetric, value: number, labels: LabelSet?) -> (),
}

function Telemetry.new(registryName: string?, flushEvery: number?, session: Session.Session)
	return setmetatable({
		_name           = registryName or "default",
		_buffer         = {},           -- pending samples
		_flushEvery     = flushEvery or 10,
		_lastFlush      = os.clock(),
		_session        = session
	}, Telemetry)
end

--[[
	Generic pushSample shared by all metric types
]]
local function pushSample(self, kind: string, name: string, value, labels: LabelSet)
	table.insert(self._buffer, {
		t  = os.time(), -- UTC seconds
		k  = kind,      -- counter | gauge | hist | sum
		n  = name,      -- metric name
		v  = value,     -- number or bucket-map
		l  = labels     -- table<string,string>
	})

	if os.clock() - self._lastFlush >= self._flushEvery then
		self:flush()
	end
end

function Telemetry:flush()
	if #self._buffer == 0 then return end
	pcall(function()
		self._session:post(
			"/telemetry/push",
			{buffer = self._buffer}
		)
	end)
	self._buffer, self._lastFlush = {}, os.clock()
end

--[[
	Creates (or fetches) a monotonically increasing **counter** metric.

	@param self  Telemetry         – the registry instance.
	@param name  string            – metric name (snake_case).
	@param opts  MetricOpts?       – optional descriptor & label schema.

	@return CounterMetric handle   – call `:inc()` to push samples.

	Example
	```lua
	local shots = registry:Counter("weapon_shots_total", {
		description = "Number of shots fired per weapon",
		labels      = {"weapon"}
	})

	shots:inc()                    -- +1
	shots:inc(3, {weapon="AK-47"}) -- +3 with a label
	```
]]--
function Telemetry:Counter(name: string, opts: MetricOpts?): CounterMetric
	local total = 0
	return ({
		inc = function(_: CounterMetric, delta: number?, lbls: LabelSet?)
			total += delta or 1
			pushSample(self, "counter", name, total, lbls or {})
		end,
	} :: any) :: CounterMetric
end

--[[
	Creates a **gauge** metric – an instantaneous value that can go up
	or down (e.g. memory, player count, FPS).

	`set()` overrides the value directly, while `inc()` / `dec()` apply
	deltas.

	@return GaugeMetric handle.
]]--
function Telemetry:Gauge(name: string, opts: MetricOpts?): GaugeMetric
	return ({

		set = function(_: GaugeMetric, value: number, lbls: LabelSet?)
			pushSample(self, "gauge", name, value, lbls or {})
		end,

		inc = function(_: GaugeMetric, delta: number?, lbls: LabelSet?)
			pushSample(self, "gauge", name,  delta or 1, lbls or {})
		end,

		dec = function(_: GaugeMetric, delta: number?, lbls: LabelSet?)
			pushSample(self, "gauge", name, -(delta or 1), lbls or {})
		end,

	} :: any) :: GaugeMetric
end

--[[
	Creates a **histogram** metric – captures a distribution of values
	(e.g. damage dealt, ping). `buckets` may be provided in `opts`.

	The raw sample value is sent unchanged; bucketing happens on the
	back-end so bucket definitions can evolve without client updates.

	@return HistogramMetric handle.
]]--
function Telemetry:Histogram(name: string, opts: MetricOpts?): HistogramMetric
	local buckets: {number}? = opts and opts.buckets
	return ({

		observe = function(_: HistogramMetric, value: number, lbls: LabelSet?)
			local combined: LabelSet = lbls and table.clone(lbls) or {}
			if buckets then combined._buckets = HttpService:JSONEncode(buckets) end
			pushSample(self, "hist", name, value, combined)
		end,

	} :: any) :: HistogramMetric
end

--[[
	Creates a **summary** metric – similar to histogram but intended
	for quantile estimation (P-style summaries). Uses a single `observe`
	method.

	@return SummaryMetric handle.
]]--
function Telemetry:Summary(name: string, opts: MetricOpts?): SummaryMetric
	return ({

		observe = function(_: SummaryMetric, value: number, lbls: LabelSet?)
			pushSample(self, "sum", name, value, lbls or {})
		end,

	} :: any) :: SummaryMetric
end

return Telemetry
