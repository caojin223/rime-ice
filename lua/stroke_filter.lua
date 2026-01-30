-- 笔画过滤器
-- 输入拼音后，按引导键激活笔画过滤，通过 h s p n/d z 五个笔画键快速过滤候选字
-- h=横 s=竖 p=撇 n=d=捺/点 z=折 x=任意笔画
--
-- 使用方法：
--   1. 输入拼音，如 wo
--   2. 按引导键（默认分号 ;）激活笔画过滤
--   3. 输入笔画码，如 pn 或 pd（撇捺）
--   4. 候选列表将只显示笔画匹配的字
--
-- 配置示例（在 rime_ice.schema.yaml 中）：
--   stroke_filter:
--     key: ";"              # 笔画引导键
--     db: stroke            # 笔画数据库名称
--     show_other_cands: true  # 是否显示不匹配的候选（置于末尾）

-- 处理 lua 中的特殊字符用于正则匹配
local function alt_lua_punc(s)
    if s then
        return s:gsub('([%.%+%-%*%?%[%]%^%$%(%)%%])', '%%%1')
    else
        return ''
    end
end

local f = {}

function f.init(env)
    local config = env.engine.schema.config
    local ns = 'stroke_filter'

    -- 笔画引导键，默认为分号
    local stroke_key = config:get_string('key_binder/stroke') or
                       config:get_string(ns .. '/key') or ';'
    env.stroke_key = stroke_key
    env.stroke_key_alt = alt_lua_punc(stroke_key)

    -- 加载笔画反查数据库
    local db_name = config:get_string(ns .. '/db') or 'stroke'
    env.stroke_db = ReverseLookup(db_name)
    if not env.stroke_db then
        log.warning('[stroke_filter.lua]: 无法加载笔画数据库 ' .. db_name)
    end

    -- 是否显示不匹配的候选（置于末尾）
    env.show_other_cands = config:get_bool(ns .. '/show_other_cands')
    if env.show_other_cands == nil then
        env.show_other_cands = true  -- 默认显示
    end

    -- seg tag
    local tag = config:get_list(ns .. '/tags')
    if tag and tag.size > 0 then
        env.tag = {}
        for i = 0, tag.size - 1 do
            table.insert(env.tag, tag:get_value_at(i).value)
        end
    else
        env.tag = { 'abc' }
    end

    -- 拼音码匹配模式，用于判断是否还有未转换的拼音
    local code_pattern = config:get_string(ns .. '/code_pattern') or '[a-z]'
    env.code_pattern = code_pattern

    -- 接管选词逻辑，选词后检查是否还有剩余拼音需要继续匹配
    env.notifier = env.engine.context.select_notifier:connect(function(ctx)
        local input = ctx.input
        -- 检查输入中是否包含笔画引导键
        local code = input:match('^(.-)' .. env.stroke_key_alt)
        if not code or #code == 0 then return end

        local preedit = ctx:get_preedit()
        local no_stroke_string = ctx.input:match('^(.-)' .. env.stroke_key_alt)
        local edit = preedit.text:match('^(.-)' .. env.stroke_key_alt)

        -- 如果 preedit 中还有未转换的拼音码，保留引导键继续匹配下一个字
        if edit and edit:match(code_pattern) then
            ctx.input = no_stroke_string .. stroke_key
        else
            -- 没有剩余拼音了，直接上屏
            ctx.input = no_stroke_string
            ctx:commit()
        end
    end)
end

-- 检查候选字的笔画是否以输入的笔画码开头
local function stroke_match(db, text, stroke_code)
    if not db then return false end

    -- 获取第一个字符（对于词组只匹配首字）
    local first_char = text
    if utf8.len(text) and utf8.len(text) > 1 then
        first_char = text:sub(1, utf8.offset(text, 2) - 1)
    end

    -- 将 x 转换为正则的 .（匹配任意单个笔画）
    local pattern = stroke_code:gsub('x', '.')

    -- 从数据库查询该字的笔画序列
    local strokes = db:lookup(first_char)
    if strokes and #strokes > 0 then
        -- 笔画数据可能有多个读音/条目，用空格分隔
        for part in strokes:gmatch('%S+') do
            -- 检查是否以输入的笔画码开头
            if part:find('^' .. pattern) then
                return true
            end
        end
    end
    return false
end

function f.func(input, env)
    -- 检查是否有笔画引导符，并提取笔画码
    -- 格式：拼音 + 引导键 + 笔画码（h/s/p/n/d/z/x 的组合，其中 d=n，x=任意笔画）
    local code, stroke = env.engine.context.input:match(
        '^(.-)' .. env.stroke_key_alt .. '([hspnzdx]*)$'
    )

    -- 没有笔画码或没有引导符，或者数据库未加载，直接输出所有候选
    if not env.stroke_db or
       not code or #code == 0 or
       not stroke or #stroke == 0 then
        for cand in input:iter() do
            yield(cand)
        end
        return
    end

    -- 将 d 转换为 n（d 和 n 等价，都表示捺/点）
    stroke = stroke:gsub('d', 'n')

    local matched_cands = {}
    local other_cands = {}

    for cand in input:iter() do
        -- 跳过造句类型的候选
        if cand.type == 'sentence' then
            goto continue
        end

        -- 检查笔画是否匹配
        if stroke_match(env.stroke_db, cand.text, stroke) then
            table.insert(matched_cands, cand)
        else
            table.insert(other_cands, cand)
        end

        ::continue::
    end

    -- 先输出匹配的候选
    for _, cand in ipairs(matched_cands) do
        yield(cand)
    end

    -- 再输出不匹配的候选（如果配置允许）
    if env.show_other_cands then
        for _, cand in ipairs(other_cands) do
            yield(cand)
        end
    end
end

function f.tags_match(seg, env)
    for _, v in ipairs(env.tag) do
        if seg.tags[v] then return true end
    end
    return false
end

function f.fini(env)
    if env.notifier then
        env.notifier:disconnect()
    end
    if env.stroke_db then
        env.stroke_db = nil
        collectgarbage('collect')
    end
end

return f
