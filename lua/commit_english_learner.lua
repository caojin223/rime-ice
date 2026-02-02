-- 英文上屏学习器
-- 功能：
-- 1. 当按回车上屏英文时，自动将该英文词条记入用户词典
-- 2. 支持与中文相同的快捷键删除已学习的英文词条（读取 editor/bindings 的 delete_candidate 配置）
--
-- 使用方法：
-- 在 engine/processors 中添加（放在 express_editor 之前）:
--   - lua_processor@*commit_english_learner
--
-- 可选配置项：
-- commit_english_learner:
--   min_length: 2      # 最小学习长度，默认 2
--   user_dict_file: en_dicts/user_en.txt  # 用户英文词典文件路径
--
-- 删除快捷键：自动读取 editor/bindings 中的 delete_candidate 配置，与中文删除方式一致
--
-- 版本：2026-02-02

local M = {}

-- 获取用户数据目录
local function get_user_data_dir()
    return rime_api and rime_api:get_user_data_dir() or ""
end

-- 判断字符串是否为纯英文（字母开头，可包含字母、数字、常见符号）
local function is_english_input(str)
    if not str or str == "" then
        return false
    end
    -- 允许字母开头，后接字母、数字、点、下划线、连字符
    return str:match("^[a-zA-Z][a-zA-Z0-9%.%_%-]*$") ~= nil
end

-- 读取已有的用户英文词条
local function load_existing_words(filepath)
    local words = {}
    local file = io.open(filepath, "r")
    if file then
        for line in file:lines() do
            -- 跳过注释和空行
            if not line:match("^#") and not line:match("^%s*$") then
                local word = line:match("^([^\t]+)")
                if word then
                    words[word:lower()] = true
                end
            end
        end
        file:close()
    end
    return words
end

-- 将新英文词条追加写入文件
local function append_word_to_file(filepath, word)
    local file = io.open(filepath, "a")
    if file then
        -- 格式：词条<Tab>编码（编码为小写）
        file:write(word .. "\t" .. word:lower() .. "\n")
        file:close()
        return true
    end
    return false
end

-- 从文件中删除指定词条
local function remove_word_from_file(filepath, word_to_remove)
    local lines = {}
    local removed = false
    local word_lower = word_to_remove:lower()
    
    -- 读取所有行
    local file = io.open(filepath, "r")
    if file then
        for line in file:lines() do
            -- 检查是否是要删除的词条
            local word = line:match("^([^\t]+)")
            if word and word:lower() == word_lower then
                removed = true  -- 标记已删除，不添加到 lines
            else
                table.insert(lines, line)
            end
        end
        file:close()
    end
    
    if removed then
        -- 重写文件
        file = io.open(filepath, "w")
        if file then
            for _, line in ipairs(lines) do
                file:write(line .. "\n")
            end
            file:close()
            return true
        end
    end
    return false
end

-- 确保文件存在，如果不存在则创建（包含文件头）
local function ensure_file_exists(filepath)
    local file = io.open(filepath, "r")
    if file then
        file:close()
        return true
    end
    
    -- 创建新文件，写入头部（格式与 cn_en.txt 一致）
    file = io.open(filepath, "w")
    if file then
        file:write("# Rime table\n")
        file:write("# coding: utf-8\n")
        file:write("#@/db_name\tuser_en.txt\n")
        file:write("#@/db_type\ttabledb\n")
        file:write("#\n")
        file:write("# 用户英文词典 - 由 commit_english_learner.lua 自动生成\n")
        file:write("# 使用与中文相同的快捷键可删除已学习的词条\n")
        file:write("# 格式：词条<Tab>编码\n")
        file:write("#\n")
        file:write("# 此行之后不能写注释\n")
        file:close()
        return true
    end
    return false
end

function M.init(env)
    local config = env.engine.schema.config
    
    -- 读取配置
    env.min_length = config:get_int("commit_english_learner/min_length") or 2
    local user_dict_file = config:get_string("commit_english_learner/user_dict_file") or "en_dicts/user_en.txt"
    
    -- 读取删除快捷键（与中文删除保持一致，从 editor/bindings 读取）
    -- 遍历 editor/bindings 找到 delete_candidate 对应的按键
    env.delete_keys = {}
    local bindings = config:get_map("editor/bindings")
    if bindings then
        for i, key in ipairs(bindings:keys()) do
            local action = config:get_string("editor/bindings/" .. key)
            if action == "delete_candidate" then
                table.insert(env.delete_keys, key)
            end
        end
    end
    -- 如果没找到，使用默认值
    if #env.delete_keys == 0 then
        env.delete_keys = {"Control+Delete", "Shift+Delete"}
    end
    
    -- 构建完整路径
    local user_data_dir = get_user_data_dir()
    if user_data_dir ~= "" then
        env.user_dict_path = user_data_dir .. "/" .. user_dict_file
    else
        env.user_dict_path = user_dict_file
    end
    
    -- 确保文件存在
    ensure_file_exists(env.user_dict_path)
    
    -- 加载已有词条到内存（避免重复写入）
    env.existing_words = load_existing_words(env.user_dict_path)
    
    log.info("[commit_english_learner] Initialized, user dict: " .. env.user_dict_path)
    log.info("[commit_english_learner] Delete keys: " .. table.concat(env.delete_keys, ", "))
end

-- 检查按键是否是删除快捷键
local function is_delete_key(key_repr, delete_keys)
    for _, k in ipairs(delete_keys) do
        if key_repr == k then
            return true
        end
    end
    return false
end

-- 检查是否是任意删除相关的按键组合
local function is_any_delete_combo(key_repr)
    -- 支持各种可能的删除快捷键组合
    local delete_combos = {
        "Control+Delete",
        "Shift+Delete",
        "Control+BackSpace",
        "Shift+BackSpace",
        "Control+Shift+Delete",
        "Control+Shift+BackSpace",
    }
    for _, combo in ipairs(delete_combos) do
        if key_repr == combo then
            return true
        end
    end
    return false
end

function M.func(key, env)
    local engine = env.engine
    local context = engine.context
    local input = context.input
    local key_repr = key:repr()

    -- 调试：记录按键（如需调试，取消下一行注释）
    -- log.info("[commit_english_learner] Key pressed: " .. key_repr)

    -- 处理删除快捷键（支持配置的快捷键 + 常见删除组合）
    local is_delete = is_delete_key(key_repr, env.delete_keys) or is_any_delete_combo(key_repr)
    
    if is_delete and not key:release() and context:has_menu() then
        local cand = context:get_selected_candidate()
        if cand then
            local cand_text = cand.text
            local cand_type = cand.type
            
            -- 调试：记录候选项信息（如需调试，取消下一行注释）
            -- log.info("[commit_english_learner] Trying to delete: " .. cand_text .. ", type: " .. tostring(cand_type))
            
            -- 检查是否是用户英文词条（在 user_en.txt 中）
            -- 不再严格检查 cand_type，只要在用户词典中就可以删除
            if env.existing_words[cand_text:lower()] then
                if remove_word_from_file(env.user_dict_path, cand_text) then
                    env.existing_words[cand_text:lower()] = nil
                    log.info("[commit_english_learner] Deleted word: " .. cand_text)
                    -- 刷新候选菜单
                    context:refresh_non_confirmed_composition()
                    return 1 -- kAccepted
                end
            end
        end
        -- 不是用户英文词条，交给其他 processor 处理
        return 2
    end

    -- 只处理回车键
    if key_repr ~= "Return" or key:release() then
        return 2 -- kNoop
    end

    -- 检查是否正在输入
    if not context:is_composing() then
        return 2
    end

    -- 只处理纯英文输入
    if not is_english_input(input) then
        return 2
    end

    -- 检查长度
    if #input < env.min_length then
        return 2
    end

    local input_lower = input:lower()
    
    -- 检查候选项中是否有完全匹配的
    if context:has_menu() then
        local seg = context.composition:back()
        if seg then
            for i = 0, seg.menu:candidate_count() - 1 do
                local cand = seg.menu:get_candidate_at(i)
                if cand and cand.text:lower() == input_lower then
                    -- 找到匹配，选择它（触发 melt_eng 的学习机制）
                    seg.selected_index = i
                    context:commit()
                    return 1 -- kAccepted
                end
            end
        end
    end

    -- 没有匹配的候选项，将英文写入用户词典文件
    if not env.existing_words[input_lower] then
        if append_word_to_file(env.user_dict_path, input) then
            env.existing_words[input_lower] = true
            log.info("[commit_english_learner] Learned new word: " .. input)
        end
    end

    -- 交给 express_editor 处理 commit_raw_input
    return 2
end

function M.fini(env)
    env.existing_words = nil
    collectgarbage("collect")
end

return M
