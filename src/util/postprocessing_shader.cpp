// SPDX-FileCopyrightText: 2019-2022 Connor McLaughlin <stenzek@gmail.com>
// SPDX-License-Identifier: (GPL-3.0 OR CC-BY-NC-ND-4.0)

#include "postprocessing_shader.h"

#include "common/file_system.h"
#include "common/log.h"
#include "common/string_util.h"

#include <cctype>
#include <cstring>
#include <sstream>

Log_SetChannel(PostProcessing);

void PostProcessing::Shader::ParseKeyValue(const std::string_view& line, std::string_view* key, std::string_view* value)
{
  size_t key_start = 0;
  while (key_start < line.size() && std::isspace(line[key_start]))
    key_start++;

  size_t key_end = key_start;
  while (key_end < line.size() && (!std::isspace(line[key_end]) && line[key_end] != '='))
    key_end++;

  if (key_start == key_end || key_end == line.size())
    return;

  size_t value_start = key_end;
  while (value_start < line.size() && std::isspace(line[value_start]))
    value_start++;

  if (value_start == line.size() || line[value_start] != '=')
    return;

  value_start++;
  while (value_start < line.size() && std::isspace(line[value_start]))
    value_start++;

  size_t value_end = line.size();
  while (value_end > value_start && std::isspace(line[value_end - 1]))
    value_end--;

  if (value_start == value_end)
    return;

  *key = line.substr(key_start, key_end - key_start);
  *value = line.substr(value_start, value_end - value_start);
}

PostProcessing::Shader::Shader() = default;

PostProcessing::Shader::Shader(std::string name) : m_name(std::move(name))
{
}

PostProcessing::Shader::~Shader() = default;

bool PostProcessing::Shader::IsValid() const
{
  return false;
}

std::vector<PostProcessing::ShaderOption> PostProcessing::Shader::TakeOptions()
{
  return std::move(m_options);
}

void PostProcessing::Shader::LoadOptions(SettingsInterface& si, const char* section)
{
  for (ShaderOption& option : m_options)
  {
    if (option.type == ShaderOption::Type::Bool)
    {
      const bool new_value = si.GetBoolValue(section, option.name.c_str(), option.default_value[0].int_value != 0);
      if ((option.value[0].int_value != 0) != new_value)
      {
        option.value[0].int_value = new_value ? 1 : 0;
        OnOptionChanged(option);
      }
    }
    else
    {
      ShaderOption::ValueVector value = option.default_value;

      std::string config_value;
      if (si.GetStringValue(section, option.name.c_str(), &config_value))
      {
        const u32 value_vector_size = (option.type == ShaderOption::Type::Int) ?
                                        ShaderOption::ParseIntVector(config_value, &value) :
                                        ShaderOption::ParseFloatVector(config_value, &value);
        if (value_vector_size != option.vector_size)
        {
          Log_WarningPrintf("Only got %u of %u elements for '%s' in config section %s.", value_vector_size,
                            option.vector_size, option.name.c_str(), section);
        }
      }

      if (std::memcmp(&option.value, &value, sizeof(value)) != 0)
      {
        option.value = value;
        OnOptionChanged(option);
      }
    }
  }
}

const PostProcessing::ShaderOption* PostProcessing::Shader::GetOptionByName(const std::string_view& name) const
{
  for (const ShaderOption& option : m_options)
  {
    if (option.name == name)
      return &option;
  }

  return nullptr;
}

PostProcessing::ShaderOption* PostProcessing::Shader::GetOptionByName(const std::string_view& name)
{
  for (ShaderOption& option : m_options)
  {
    if (option.name == name)
      return &option;
  }

  return nullptr;
}

void PostProcessing::Shader::OnOptionChanged(const ShaderOption& option)
{
}
