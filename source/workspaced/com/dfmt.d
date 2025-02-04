module workspaced.com.dfmt;

import fs = std.file;
import std.algorithm;
import std.array;
import std.conv;
import std.getopt;
import std.json;
import std.stdio : stderr;

import dfmt.config;
import dfmt.editorconfig;
import dfmt.formatter : fmt = format;

import core.thread;

import painlessjson;

import workspaced.api;

@component("dfmt")
class DfmtComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	/// Will format the code passed in asynchronously.
	/// Returns: the formatted code as string
	Future!string format(scope const(char)[] code, string[] arguments = [])
	{
		mixin(gthreadsAsyncProxy!`formatSync(code, arguments)`);
	}

	/// Will format the code passed in synchronously. Might take a short moment on larger documents.
	/// Returns: the formatted code as string
	string formatSync(scope const(char)[] code, string[] arguments = [])
	{
		Config config;
		config.initializeWithDefaults();
		string configPath;
		if (getConfigPath("dfmt.json", configPath))
		{
			stderr.writeln("Overriding dfmt arguments with workspace-d dfmt.json config file");
			try
			{
				auto json = parseJSON(fs.readText(configPath));
				foreach (i, ref member; config.tupleof)
				{
					enum name = __traits(identifier, config.tupleof[i]);
					if (name.startsWith("dfmt_"))
						json.tryFetchProperty(member, name["dfmt_".length .. $]);
					else
						json.tryFetchProperty(member, name);
				}
			}
			catch (Exception e)
			{
				stderr.writeln("dfmt.json in workspace-d config folder is malformed");
				stderr.writeln(e);
			}
		}
		else if (arguments.length)
		{
			// code for parsing args from dfmt main.d (keep up-to-date!)
			// https://github.com/dlang-community/dfmt/blob/master/src/dfmt/main.d
			void handleBooleans(string option, string value)
			{
				import dfmt.editorconfig : OptionalBoolean;
				import std.exception : enforce;

				enforce!GetOptException(value == "true" || value == "false", "Invalid argument");
				immutable OptionalBoolean val = value == "true" ? OptionalBoolean.t : OptionalBoolean.f;
				switch (option)
				{
				case "align_switch_statements":
					config.dfmt_align_switch_statements = val;
					break;
				case "outdent_attributes":
					config.dfmt_outdent_attributes = val;
					break;
				case "space_after_cast":
					config.dfmt_space_after_cast = val;
					break;
				case "space_before_function_parameters":
					config.dfmt_space_before_function_parameters = val;
					break;
				case "split_operator_at_line_end":
					config.dfmt_split_operator_at_line_end = val;
					break;
				case "selective_import_space":
					config.dfmt_selective_import_space = val;
					break;
				case "compact_labeled_statements":
					config.dfmt_compact_labeled_statements = val;
					break;
				case "single_template_constraint_indent":
					config.dfmt_single_template_constraint_indent = val;
					break;
				case "space_before_aa_colon":
					config.dfmt_space_before_aa_colon = val;
					break;
				case "keep_line_breaks":
					config.dfmt_keep_line_breaks = val;
					break;
				default:
					throw new Exception("Invalid command-line switch");
				}
			}

			arguments = "dfmt" ~ arguments;

			// this too keep up-to-date
			// everything except "version", "config", "help", "inplace" arguments

			//dfmt off
			getopt(arguments,
				"align_switch_statements", &handleBooleans,
				"brace_style", &config.dfmt_brace_style,
				"end_of_line", &config.end_of_line,
				"indent_size", &config.indent_size,
				"indent_style|t", &config.indent_style,
				"max_line_length", &config.max_line_length,
				"soft_max_line_length", &config.dfmt_soft_max_line_length,
				"outdent_attributes", &handleBooleans,
				"space_after_cast", &handleBooleans,
				"selective_import_space", &handleBooleans,
				"space_before_function_parameters", &handleBooleans,
				"split_operator_at_line_end", &handleBooleans,
				"compact_labeled_statements", &handleBooleans,
				"single_template_constraint_indent", &handleBooleans,
				"space_before_aa_colon", &handleBooleans,
				"tab_width", &config.tab_width,
				"template_constraint_style", &config.dfmt_template_constraint_style,
				"keep_line_breaks", &handleBooleans
			);
			//dfmt on
		}
		auto output = appender!string;
		fmt("stdin", cast(ubyte[]) code, output, &config);
		if (output.data.length)
			return output.data;
		else
			return code.idup;
	}
}

private:

void tryFetchProperty(T = string)(ref JSONValue json, ref T ret, string name)
{
	auto ptr = name in json;
	if (ptr)
	{
		auto val = *ptr;
		static if (is(T == string) || is(T == enum))
		{
			if (val.type != JSONType.string)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a string");
			static if (is(T == enum))
				ret = val.str.to!T;
			else
				ret = val.str;
		}
		else static if (is(T == uint))
		{
			if (val.type != JSONType.integer)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			if (val.integer < 0)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a positive number");
			ret = cast(T) val.integer;
		}
		else static if (is(T == int))
		{
			if (val.type != JSONType.integer)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a number");
			ret = cast(T) val.integer;
		}
		else static if (is(T == OptionalBoolean))
		{
			if (val.type != JSONType.true_ && val.type != JSONType.false_)
				throw new Exception("dfmt config value '" ~ name ~ "' must be a boolean");
			ret = val.type == JSONType.true_ ? OptionalBoolean.t : OptionalBoolean.f;
		}
		else
			static assert(false);
	}
}
