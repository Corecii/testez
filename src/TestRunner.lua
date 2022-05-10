--[[
	Contains the logic to run a test plan and gather test results from it.

	TestRunner accepts a TestPlan object, executes the planned tests, and
	produces a TestResults object. While the tests are running, the system's
	state is contained inside a TestSession object.
]]

local TestEnum = require(script.Parent.TestEnum)
local TestSession = require(script.Parent.TestSession)
local LifecycleHooks = require(script.Parent.LifecycleHooks)

local RUNNING_GLOBAL = "__TESTEZ_RUNNING_TEST__"

local TestRunner = {
	environment = {}
}

local function wrapExpectContextWithPublicApi(expectationContext)
	return setmetatable({
		extend = function(...)
			expectationContext:extend(...)
		end,
	}, {
		__call = function(_self, ...)
			return expectationContext:startExpectationChain(...)
		end,
	})
end

--[[
	Runs the given TestPlan and returns a TestResults object representing the
	results of the run.
]]
function TestRunner.runPlan(plan)
	local session = TestSession.new(plan)
	local lifecycleHooks = LifecycleHooks.new()

	local exclusiveNodes = plan:findNodes(function(node)
		return node.modifier == TestEnum.NodeModifier.Focus
	end)

	session.hasFocusNodes = #exclusiveNodes > 0

	TestRunner.runPlanNode(session, plan, lifecycleHooks)

	return session:finalize()
end

--[[
	Run the given test plan node and its descendants, using the given test
	session to store all of the results.
]]
function TestRunner.runPlanNode(session, planNode, lifecycleHooks)
	local function runCallback(callback, messagePrefix, ...)
		local success = true
		local errorMessage
		-- Any code can check RUNNING_GLOBAL to fork behavior based on
		-- whether a test is running. We use this to avoid accessing
		-- protected APIs; it's a workaround that will go away someday.
		_G[RUNNING_GLOBAL] = true

		messagePrefix = messagePrefix or ""

		local testEnvironment = getfenv(callback)

		for key, value in pairs(TestRunner.environment) do
			testEnvironment[key] = value
		end

		testEnvironment.fail = function(message)
			if message == nil then
				message = "fail() was called."
			end

			success = false
			errorMessage = messagePrefix .. debug.traceback(tostring(message), 2)
		end

		testEnvironment.expect = wrapExpectContextWithPublicApi(session:getExpectationContext())

		local context = session:getContext()

		local nodeResult = table.pack(xpcall(
			function(...)
				return callback(context, ...)
			end,
			function(message)
				return messagePrefix .. debug.traceback(tostring(message), 2)
			end,
			...
		))

		local result
		local nodeSuccess = nodeResult[1]

		-- If a node threw an error, we prefer to use that message over
		-- one created by fail() if it was set.
		if not nodeSuccess then
			result = {
				success = false,
				error = nodeResult[2]
			}
		else
			result = {
				success = true,
				returns = table.pack(unpack(nodeResult, 2, nodeResult.n))
			}
		end

		_G[RUNNING_GLOBAL] = nil

		return result
	end

	local function runNode(childPlanNode)
		-- Errors can be set either via `error` propagating upwards or
		-- by a test calling fail([message]).

		for _, hook in ipairs(lifecycleHooks:getBeforeEachHooks()) do
			local result = runCallback(hook, "beforeEach hook: ")
			if not result.success then
				return false, result.error
			end
		end

		local callback = childPlanNode.callback
		for _, hook in ipairs(lifecycleHooks:getWrapEachHooks()) do
			local result = runCallback(hook, nil, callback)
			if not result.success then
				return false, result.error
			elseif typeof(result.returns[1]) ~= "function" then
				return false, "expected wrapEach to return a function, but instead it returned " .. typeof(result.returns[1])
			else
				callback = result.returns[1]
			end
		end

		local testResult = runCallback(callback)

		for _, hook in ipairs(lifecycleHooks:getAfterEachHooks()) do
			local result = runCallback(hook, "afterEach hook: ")
			if not result.success then
				if not testResult.success then
					return false, testResult.error .. "\nWhile cleaning up the failed test another error was found:\n" .. result.error
				end
				return false, result.error
			end
		end

		if not testResult.success then
			return false, testResult.error
		end

		return true, nil
	end

	lifecycleHooks:pushHooksFrom(planNode)

	local halt = false
	for _, hook in ipairs(lifecycleHooks:getBeforeAllHooks()) do
		local result = runCallback(hook, "beforeAll hook: ")
		if not result.success then
			session:addDummyError("beforeAll", result.error)
			halt = true
		end
	end

	if not halt then
		for _, childPlanNode in ipairs(planNode.children) do
			if childPlanNode.type == TestEnum.NodeType.It then
				session:pushNode(childPlanNode)
				if session:shouldSkip() then
					session:setSkipped()
				else
					local success, errorMessage = runNode(childPlanNode)

					if success then
						session:setSuccess()
					else
						session:setError(errorMessage)
					end
				end
				session:popNode()
			elseif childPlanNode.type == TestEnum.NodeType.Describe then
				session:pushNode(childPlanNode)
				TestRunner.runPlanNode(session, childPlanNode, lifecycleHooks)

				-- Did we have an error trying build a test plan?
				if childPlanNode.loadError then
					local message = "Error during planning: " .. childPlanNode.loadError
					session:setError(message)
				else
					session:setStatusFromChildren()
				end
				session:popNode()
			end
		end
	end

	for _, hook in ipairs(lifecycleHooks:getAfterAllHooks()) do
		local result = runCallback(hook, "afterAll hook: ")
		if not result.success then
			session:addDummyError("afterAll", result.error)
		end
	end

	lifecycleHooks:popHooks()
end

return TestRunner
