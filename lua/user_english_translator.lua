-- 用户英文翻译器
-- 功能：动态读取 user_en.txt，让新学习的英文词条即时出现在候选项中（无需重新部署）
--
-- 使用方法：
-- 在 engine/translators 中添加:
--   - lua_translator@*user_english_translator
--
-- 可选配置项：
-- user_english_translator:
--   user_dict_file: en_dicts/user_en.txt  # 用户英文词典文件路径
--
-- 版本：2026-02-02

local M = {}

-- 获取用户数据目录
local function get_user_data_dir()
    return rime_api and rime_api:get_user_data_dir() or ""
end

-- 读取用户英文词典
local function load_user_words(filepath)
    local words = {}
    local file = io.open(filepath, "r")
    if file then
        for line in file:lines() do
            -- 跳过注释和空行
            if not line:match("^#") and not line:match("^%s*$") then
                local word, code = line:match("^([^\t]+)\t([^\t]+)")
                if word and code then
                    -- 存储：编码（小写） -> 词条
                    local code_lower = code:lower()
                    if not words[code_lower] then
                        words[code_lower] = {}
                    end
                    table.insert(words[code_lower], word)
                end
            end
        end
        file:close()
    end
    return words
end

-- 获取文件修改时间（用于检测文件变化）
local function get_file_mtime(filepath)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        -- Lua 没有直接获取 mtime 的方法，用文件内容长度作为简单的变化检测
        local f = io.open(filepath, "r")
        if f then
            local content = f:read("*a")
            f:close()
            return #content
        end
    end
    return 0
end

function M.init(env)
    local config = env.engine.schema.config
    
    -- 读取配置
    local user_dict_file = config:get_string("user_english_translator/user_dict_file") 
        or config:get_string("commit_english_learner/user_dict_file") 
        or "en_dicts/user_en.txt"
    
    -- 构建完整路径
    local user_data_dir = get_user_data_dir()
    if user_data_dir ~= "" then
        env.user_dict_path = user_data_dir .. "/" .. user_dict_file
    else
        env.user_dict_path = user_dict_file
    end
    
    -- 初始加载词典
    env.user_words = load_user_words(env.user_dict_path)
    env.last_mtime = get_file_mtime(env.user_dict_path)
    
    -- 统计加载的词条数量
    local count = 0
    for _ in pairs(env.user_words) do
        count = count + 1
    end
    log.info("[user_english_translator] Loaded " .. count .. " entries from " .. env.user_dict_path)
end

function M.func(input, seg, env)
    -- 检查输入是否为纯英文
    if not input:match("^[a-zA-Z][a-zA-Z0-9%.%_%-]*$") then
        return
    end
    
    local input_lower = input:lower()
    
    -- 检查文件是否有更新，如果有则重新加载
    local current_mtime = get_file_mtime(env.user_dict_path)
    if current_mtime ~= env.last_mtime then
        env.user_words = load_user_words(env.user_dict_path)
        env.last_mtime = current_mtime
    end
    
    -- 查找完全匹配的词条
    if env.user_words[input_lower] then
        for _, word in ipairs(env.user_words[input_lower]) do
            local cand = Candidate("user_english", seg.start, seg._end, word, "☆")
            cand.quality = 100  -- 高权重，确保排在前面
            yield(cand)
        end
    end
    
    -- 查找前缀匹配的词条（补全功能）
    for code, words in pairs(env.user_words) do
        if code ~= input_lower and code:sub(1, #input_lower) == input_lower then
            for _, word in ipairs(words) do
                local cand = Candidate("user_english", seg.start, seg._end, word, "~")
                cand.quality = 50
                yield(cand)
            end
        end
    end
end

function M.fini(env)
    env.user_words = nil
    collectgarbage("collect")
end

return M
