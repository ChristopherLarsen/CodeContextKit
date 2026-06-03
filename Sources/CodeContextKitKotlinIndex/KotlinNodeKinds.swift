import Foundation

enum KotlinNodeKind {
    static let packageHeader = "package_header"
    static let classDeclaration = "class_declaration"
    static let objectDeclaration = "object_declaration"
    static let companionObject = "companion_object"
    static let functionDeclaration = "function_declaration"
    static let propertyDeclaration = "property_declaration"
    static let classParameter = "class_parameter"
    static let primaryConstructor = "primary_constructor"
    static let secondaryConstructor = "secondary_constructor"
    static let typeAlias = "type_alias"
    static let enumEntry = "enum_entry"
    static let infixExpression = "infix_expression"
    static let callExpression = "call_expression"
    static let navigationExpression = "navigation_expression"
    static let userType = "user_type"
}
