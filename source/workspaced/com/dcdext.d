module workspaced.com.dcdext;

import dparse.ast;
import dparse.lexer;
import dparse.parser;
import dparse.rollback_allocator;

import core.thread;

import std.algorithm;
import std.array;
import std.ascii;
import std.file;
import std.functional;
import std.json;
import std.range;
import std.string;

import workspaced.api;
import workspaced.dparseext;
import workspaced.com.dcd;

import workspaced.visitors.classifier;
import workspaced.visitors.methodfinder;

@component("dcdext")
class DCDExtComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	static immutable CodeRegionProtection[] mixableProtection = [
		CodeRegionProtection.public_ | CodeRegionProtection.default_, CodeRegionProtection.package_,
		CodeRegionProtection.packageIdentifier, CodeRegionProtection.protected_,
		CodeRegionProtection.private_
	];

	/// Loads dcd extension methods. Call with `{"cmd": "load", "components": ["dcdext"]}`
	void load()
	{
		if (!refInstance)
			return;

		config.stringBehavior = StringBehavior.source;
	}

	/// Finds the immediate surrounding code block at a position or returns CodeBlockInfo.init for none/module block.
	/// See_Also: CodeBlockInfo
	CodeBlockInfo getCodeBlockRange(string code, int position)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, "getCodeBlockRange_input.d", &rba);
		auto reader = new CodeBlockInfoFinder(position);
		reader.visit(parsed);
		return reader.block;
	}

	/// Inserts a generic method after the corresponding block inside the scope where position is.
	/// If it can't find a good spot it will insert the code properly indented ata fitting location.
	// make public once usable
	private CodeReplacement[] insertCodeInContainer(string insert, string code,
			int position, bool insertInLastBlock = true, bool insertAtEnd = true)
	{
		auto container = getCodeBlockRange(code, position);

		string codeBlock = code[container.innerRange[0] .. container.innerRange[1]];

		scope tokensInsert = getTokensForParser(cast(ubyte[]) insert, config,
				&workspaced.stringCache);
		scope parsedInsert = parseModule(tokensInsert, "insertCode_insert.d", &rba);

		scope insertReader = new CodeDefinitionClassifier(insert);
		insertReader.visit(parsedInsert);
		scope insertRegions = insertReader.regions.sort!"a.type < b.type".uniq.array;

		scope tokens = getTokensForParser(cast(ubyte[]) codeBlock, config, &workspaced.stringCache);
		scope parsed = parseModule(tokens, "insertCode_code.d", &rba);

		scope reader = new CodeDefinitionClassifier(codeBlock);
		reader.visit(parsed);
		scope regions = reader.regions;

		CodeReplacement[] ret;

		foreach (CodeDefinitionClassifier.Region toInsert; insertRegions)
		{
			auto insertCode = insert[toInsert.region[0] .. toInsert.region[1]];
			scope existing = regions.enumerate.filter!(a => a.value.sameBlockAs(toInsert));
			if (existing.empty)
			{
				auto checkProtection = mixableProtection.filter!(a => (a & toInsert.protection) != 0)
					.reduce!"a | b";

				bool inIncompatible = false;
				bool lastFit = false;
				int fittingProtection = -1;
				int firstStickyProtection = -1;
				int regionAfterFitting = -1;
				foreach (i, stickyProtection; regions)
				{
					if (stickyProtection.affectsFollowing
							&& stickyProtection.protection != CodeRegionProtection.init)
					{
						if (firstStickyProtection == -1)
							firstStickyProtection = cast(int) i;

						if ((stickyProtection.protection & checkProtection) != 0)
						{
							fittingProtection = cast(int) i;
							lastFit = true;
							if (!insertInLastBlock)
								break;
						}
						else
						{
							if (lastFit)
							{
								regionAfterFitting = cast(int) i;
								lastFit = false;
							}
							inIncompatible = true;
						}
					}
				}
				assert(firstStickyProtection != -1 || !inIncompatible);
				assert(regionAfterFitting != -1 || fittingProtection == -1 || !inIncompatible);

				if (inIncompatible)
				{
					int insertRegion = fittingProtection == -1 ? firstStickyProtection : regionAfterFitting;
					insertCode = indent(insertCode, regions[insertRegion].minIndentation) ~ "\n\n";
					auto len = cast(uint) insertCode.length;

					toInsert.region[0] = regions[insertRegion].region[0];
					toInsert.region[1] = regions[insertRegion].region[0] + len;
					foreach (ref r; regions[insertRegion .. $])
					{
						r.region[0] += len;
						r.region[1] += len;
					}
				}
				else
				{
					auto lastRegion = regions.back;
					insertCode = indent(insertCode, lastRegion.minIndentation);
					auto len = cast(uint) insertCode.length;
					toInsert.region[0] = lastRegion.region[1];
					toInsert.region[1] = lastRegion.region[1] + len;
				}
				regions ~= toInsert;
				ret ~= CodeReplacement([toInsert.region[0], toInsert.region[0]], insertCode);
			}
			else
			{
				auto target = insertInLastBlock ? existing.tail(1).front : existing.front;

				insertCode = "\n\n" ~ indent(insertCode, regions[target.index].minIndentation);
				const codeLength = cast(int) insertCode.length;

				if (insertAtEnd)
				{
					ret ~= CodeReplacement([target.value.region[1], target.value.region[1]], insertCode);
					toInsert.region[0] = target.value.region[1];
					toInsert.region[1] = target.value.region[1] + codeLength;
					regions[target.index].region[1] = toInsert.region[1];
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
				else
				{
					ret ~= CodeReplacement([target.value.region[0], target.value.region[0]], insertCode);
					regions[target.index].region[1] += codeLength;
					foreach (ref other; regions[target.index + 1 .. $])
					{
						other.region[0] += codeLength;
						other.region[1] += codeLength;
					}
				}
			}
		}

		return ret;
	}

	/// Implements the interfaces or abstract classes of a specified class/interface.
	Future!string implement(string code, int position)
	{
		auto ret = new Future!string;
		new Thread({
			try
			{
				struct InterfaceTree
				{
					InterfaceDetails details;
					InterfaceTree[] inherits;
				}

				auto baseInterface = getInterfaceDetails("stdin", code, position);

				string[] implementedMethods = baseInterface.methods
					.filter!"!a.needsImplementation"
					.map!"a.identifier"
					.array;

				// start with private, add all the public ones later in traverseTree
				FieldDetails[] availableVariables = baseInterface.fields.filter!"a.isPrivate".array;
				InterfaceTree tree = InterfaceTree(baseInterface);

				InterfaceTree* treeByName(InterfaceTree* tree, string name)
				{
					if (tree.details.name == name)
						return tree;
					foreach (ref parent; tree.inherits)
					{
						InterfaceTree* t = treeByName(&parent, name);
						if (t !is null)
							return t;
					}
					return null;
				}

				void traverseTree(ref InterfaceTree sub)
				{
					availableVariables ~= sub.details.fields.filter!"!a.isPrivate".array;
					foreach (i, parent; sub.details.parentPositions)
					{
						string parentName = sub.details.normalizedParents[i];
						if (treeByName(&tree, parentName) is null)
						{
							auto details = lookupInterface(sub.details.code, parent);
							sub.inherits ~= InterfaceTree(details);
						}
					}
					foreach (ref inherit; sub.inherits)
						traverseTree(inherit);
				}

				traverseTree(tree);

				string changes;
				void processTree(ref InterfaceTree tree)
				{
					auto details = tree.details;
					if (details.methods.length)
					{
						bool first = true;
						foreach (fn; details.methods)
						{
							if (implementedMethods.canFind(fn.identifier))
								continue;
							if (!fn.needsImplementation)
							{
								implementedMethods ~= fn.identifier;
								continue;
							}
							if (first)
							{
								changes ~= "// implement " ~ details.name ~ "\n\n";
								first = false;
							}
							if (details.needsOverride)
								changes ~= "override ";
							changes ~= fn.signature[0 .. $ - 1];
							changes ~= " {";
							if (fn.optionalImplementation)
							{
								changes ~= "\n\t// TODO: optional implementation\n";
							}

							string propertySearch;
							if (fn.signature.canFind("@property") && fn.arguments.length <= 1)
								propertySearch = fn.name;
							else if ((fn.name.startsWith("get") && fn.arguments.length == 0)
								|| (fn.name.startsWith("set") && fn.arguments.length == 1))
								propertySearch = fn.name[3 .. $];

							string foundProperty;
							if (propertySearch)
							{
								foreach (variable; availableVariables)
								{
									if (fieldNameMatches(variable.name, propertySearch))
									{
										foundProperty = variable.name;
										break;
									}
								}
							}

							if (foundProperty.length)
							{
								changes ~= "\n\t";
								if (fn.returnType != "void")
									changes ~= "return ";
								if (fn.name.startsWith("set") || fn.arguments.length == 1)
									changes ~= foundProperty ~ " = " ~ fn.arguments[0].name;
								else
									changes ~= foundProperty;
								changes ~= ";\n";
							}
							else if (fn.hasBody)
							{
								changes ~= "\n\t";
								if (fn.returnType != "void")
									changes ~= "return ";
								changes ~= "super." ~ fn.name;
								if (fn.arguments.length)
									changes ~= "(" ~ format("%(%s, %)", fn.arguments) ~ ")";
								else if (fn.returnType == "void")
									changes ~= "()"; // make functions that don't return add (), otherwise they might be attributes and don't need that
								changes ~= ";\n";
							}
							else if (fn.returnType != "void")
							{
								changes ~= "\n\t";
								if (fn.isNothrowOrNogc)
								{
									if (fn.returnType.endsWith("[]"))
										changes ~= "return null; // TODO: implement";
									else
										changes ~= "return " ~ fn.returnType ~ ".init; // TODO: implement";
								}
								else
									changes ~= `assert(false, "Method ` ~ fn.name ~ ` not implemented");`;
								changes ~= "\n";
							}
							changes ~= "}\n\n";
						}
					}

					foreach (parent; tree.inherits)
						processTree(parent);
				}

				processTree(tree);

				ret.finish(changes);
			}
			catch (Throwable t)
			{
				ret.error(t);
			}
		}).start();
		return ret;
	}

private:
	RollbackAllocator rba;
	LexerConfig config;

	InterfaceDetails lookupInterface(string code, int position)
	{
		auto data = get!DCDComponent.findDeclaration(code, position).getBlocking;
		string file = data.file;
		int newPosition = data.position;

		if (!file.length)
			return InterfaceDetails.init;

		string newCode = code;
		if (file != "stdin")
			newCode = readText(file);

		return getInterfaceDetails(file, newCode, newPosition);
	}

	InterfaceDetails getInterfaceDetails(string file, string code, int position)
	{
		auto tokens = getTokensForParser(cast(ubyte[]) code, config, &workspaced.stringCache);
		auto parsed = parseModule(tokens, file, &rba);
		auto reader = new InterfaceMethodFinder(code, position);
		reader.visit(parsed);
		return reader.details;
	}
}

///
enum CodeRegionType : int
{
	/// Imports inside the block
	imports = 1 << 0,
	/// Aliases `alias foo this;`, `alias Type = Other;`
	aliases = 1 << 1,
	/// Nested classes/structs/unions/etc.
	types = 1 << 2,
	/// Raw variables `Type name;`
	fields = 1 << 3,
	/// Normal constructors `this(Args args)`
	ctor = 1 << 4,
	/// Copy constructors `this(this)`
	copyctor = 1 << 5,
	/// Destructors `~this()`
	dtor = 1 << 6,
	/// Properties (functions annotated with `@property`)
	properties = 1 << 7,
	/// Regular functions
	methods = 1 << 8,
}

///
enum CodeRegionProtection : int
{
	/// default (unmarked) protection
	default_ = 1 << 0,
	/// public protection
	public_ = 1 << 1,
	/// package (automatic) protection
	package_ = 1 << 2,
	/// package (manual package name) protection
	packageIdentifier = 1 << 3,
	/// protected protection
	protected_ = 1 << 4,
	/// private protection
	private_ = 1 << 5,
}

///
enum CodeRegionStatic : int
{
	/// non-static code
	instanced = 1 << 0,
	/// static code
	static_ = 1 << 1,
}

/// Represents a class/interface/struct/union/template with body.
struct CodeBlockInfo
{
	///
	enum Type : int
	{
		// keep the underlines in these values for range checking properly

		///
		class_,
		///
		interface_,
		///
		struct_,
		///
		union_,
		///
		template_,
	}

	static immutable string[] typePrefixes = [
		"class ", "interface ", "struct ", "union ", "template "
	];

	///
	Type type;
	///
	string name;
	/// Outer range inside the code spanning curly braces and name but not type keyword.
	uint[2] outerRange;
	/// Inner range of body of the block touching, but not spanning curly braces.
	uint[2] innerRange;

	string prefix() @property
	{
		return typePrefixes[cast(int) type];
	}
}

private:

string indent(string code, string indentation)
{
	return code.lineSplitter!(KeepTerminator.yes).map!(a => a.length ? indentation ~ a : a).join;
}

bool fieldNameMatches(string field, in char[] expected)
{
	import std.uni : sicmp;

	if (field.startsWith("_"))
		field = field[1 .. $];
	else if (field.startsWith("m_"))
		field = field[2 .. $];
	else if (field.length >= 2 && field[0] == 'm' && field[1].isUpper)
		field = field[1 .. $];

	return field.sicmp(expected) == 0;
}

final class CodeBlockInfoFinder : ASTVisitor
{
	this(int targetPosition)
	{
		this.targetPosition = targetPosition;
	}

	override void visit(const ClassDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.class_, dec.structBody);
	}

	override void visit(const InterfaceDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.interface_, dec.structBody);
	}

	override void visit(const StructDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.struct_, dec.structBody);
	}

	override void visit(const UnionDeclaration dec)
	{
		visitContainer(dec.name, CodeBlockInfo.Type.union_, dec.structBody);
	}

	override void visit(const TemplateDeclaration dec)
	{
		if (cast(int) targetPosition >= cast(int) dec.name.index && targetPosition < dec.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = CodeBlockInfo.Type.template_;
			block.name = dec.name.text;
			block.outerRange = [cast(uint) dec.name.index, cast(uint) dec.endLocation + 1];
			block.innerRange = [cast(uint) dec.startLocation + 1, cast(uint) dec.endLocation];
			dec.accept(this);
		}
	}

	private void visitContainer(const Token name, CodeBlockInfo.Type type, const StructBody structBody)
	{
		if (!structBody)
			return;
		if (cast(int) targetPosition >= cast(int) name.index && targetPosition < structBody.endLocation)
		{
			block = CodeBlockInfo.init;
			block.type = type;
			block.name = name.text;
			block.outerRange = [cast(uint) name.index, cast(uint) structBody.endLocation + 1];
			block.innerRange = [cast(uint) structBody.startLocation + 1, cast(uint) structBody
				.endLocation];
			structBody.accept(this);
		}
	}

	alias visit = ASTVisitor.visit;

	CodeBlockInfo block;
	int targetPosition;
}

version (unittest) static immutable string SimpleClassTestCode = q{
module foo;

class FooBar
{
public:
	int i; // default instanced fields
	string s;
	long l;

	public this() // public instanced ctor
	{
		i = 4;
	}

protected:
	int x;

private:
	static const int foo() @nogc nothrow pure @system // private static methods
	{
		if (s == "a")
		{
			i = 5;
		}
	}

	static void bar1() {}

	void bar2() {} // private instanced methods
	void bar3() {}
}};

unittest
{
	auto backend = new WorkspaceD();
	auto workspace = makeTemporaryTestingWorkspace;
	auto instance = backend.addInstance(workspace.directory);
	backend.register!DCDExtComponent;
	DCDExtComponent dcdext = instance.get!DCDExtComponent;

	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 123) == CodeBlockInfo(CodeBlockInfo.Type.class_,
			"FooBar", [20, SimpleClassTestCode.length], [28, SimpleClassTestCode.length - 1]));
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 19) == CodeBlockInfo.init);
	assert(dcdext.getCodeBlockRange(SimpleClassTestCode, 20) != CodeBlockInfo.init);

	auto replacements = dcdext.insertCodeInContainer("void foo()\n{\n\twriteln();\n}",
			SimpleClassTestCode, 123);
	import std.stdio;

	stderr.writeln(replacements);
}
