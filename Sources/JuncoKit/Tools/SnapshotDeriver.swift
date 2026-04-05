// SnapshotDeriver.swift — Derive template fields from ProjectSnapshot
//
// Reduces the LLM's job from filling 8-9 fields to 3-4 fields.
// Fields that can be derived from the existing project types are
// computed deterministically with zero LLM calls.

import Foundation

/// Derives full template intents from reduced LLM intents + ProjectSnapshot.
/// Pure-function struct — no LLM calls, no side effects.
public struct SnapshotDeriver: Sendable {

  public init() {}

  // MARK: - ViewModel Derivation

  /// Derive a full ViewModelFlatIntent from a reduced 4-field intent + snapshot.
  /// Returns nil if the snapshot lacks the necessary service data.
  public func deriveViewModel(
    reduced: ViewModelReducedIntent,
    snapshot: ProjectSnapshot
  ) -> ViewModelFlatIntent? {
    // Find the first service in the snapshot
    guard let service = snapshot.services.first(where: {
      $0.kind == "actor" || $0.name.hasSuffix("Service") || $0.name.hasSuffix("Manager")
    }) ?? snapshot.services.first else { return nil }

    // Derive serviceCall from the service's methods + ViewModel properties
    let serviceCall = deriveServiceCall(
      methodName: reduced.methodName,
      property2: reduced.property2,
      service: service
    )

    // Derive targetProperty from property1 declaration
    let targetProperty = extractPropertyName(reduced.property1) ?? "items"

    return ViewModelFlatIntent(
      className: reduced.className,
      property1: reduced.property1,
      property2: reduced.property2,
      property3: "",
      serviceName: service.name,
      methodName: reduced.methodName,
      serviceCall: serviceCall,
      targetProperty: targetProperty
    )
  }

  // MARK: - ListView Derivation

  /// Derive a full ListViewFlatIntent from a reduced 3-field intent + snapshot.
  /// Returns nil if the snapshot lacks ViewModel + Model data.
  public func deriveListView(
    reduced: ListViewReducedIntent,
    snapshot: ProjectSnapshot
  ) -> ListViewFlatIntent? {
    // Find the ViewModel
    let allTypes = snapshot.services + snapshot.models
    guard let vm = allTypes.first(where: { $0.name.contains("ViewModel") }) else { return nil }

    // Find the Model (not ViewModel, not Service)
    let models = snapshot.models.filter { !$0.name.contains("ViewModel") }
    guard let model = models.first else { return nil }

    // Derive listProperty: first array property in ViewModel
    let listProperty = vm.properties
      .first(where: { $0.contains("[") })
      .flatMap { extractPropertyName($0) }
      ?? vm.properties.first.flatMap { extractPropertyName($0) }
      ?? "items"

    // Derive titleProperty: first non-id property of the model
    let displayProps = model.properties.filter { prop in
      let name = extractPropertyName(prop) ?? prop
      return name != "id" && name != "uuid"
    }
    let titleProperty = displayProps.first
      .flatMap { extractPropertyName($0) }
      ?? model.properties.first
      ?? "name"

    // Derive subtitleProperty: second non-id property of the model
    let subtitleProperty: String
    if displayProps.count > 1 {
      subtitleProperty = extractPropertyName(displayProps[1]) ?? displayProps[1]
    } else {
      subtitleProperty = ""
    }

    // Derive searchProperty: ViewModel property containing "search"
    let searchProperty = vm.properties
      .first(where: { $0.lowercased().contains("search") })
      .flatMap { extractPropertyName($0) }
      ?? ""

    // Derive loadMethod: first method of ViewModel
    let loadMethod = vm.methods.first ?? "load"

    return ListViewFlatIntent(
      viewName: reduced.viewName,
      viewModelType: vm.name,
      listProperty: listProperty,
      itemType: reduced.itemType,
      titleProperty: titleProperty,
      subtitleProperty: subtitleProperty,
      searchProperty: searchProperty,
      loadMethod: loadMethod,
      navigationTitle: reduced.navigationTitle
    )
  }

  // MARK: - Helpers

  /// Extract a property name from a declaration string.
  /// "var podcasts: [Podcast] = []" → "podcasts"
  /// "podcasts" → "podcasts"
  public func extractPropertyName(_ declaration: String) -> String? {
    let trimmed = declaration.trimmingCharacters(in: .whitespaces)
    let stripped: String
    if trimmed.hasPrefix("var ") {
      stripped = String(trimmed.dropFirst(4))
    } else if trimmed.hasPrefix("let ") {
      stripped = String(trimmed.dropFirst(4))
    } else if trimmed.hasPrefix("@Published var ") {
      stripped = String(trimmed.dropFirst(15))
    } else {
      stripped = trimmed
    }
    let name = stripped.split(separator: ":").first
      .map { String($0).trimmingCharacters(in: .whitespaces) }
    guard let name, !name.isEmpty else { return nil }
    return name
  }

  /// Derive a service call expression by matching the ViewModel's method
  /// to a service method and binding ViewModel properties as arguments.
  private func deriveServiceCall(
    methodName: String,
    property2: String,
    service: TypeSummary
  ) -> String {
    // Find the service method that contains the method name
    let matchedMethod = service.methods.first(where: {
      $0.lowercased().contains(methodName.lowercased())
    }) ?? service.methods.first ?? methodName

    // Extract the base method name (before parenthesis)
    let baseName = matchedMethod.split(separator: "(").first
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      ?? matchedMethod

    // Extract the property2 name for parameter binding
    let prop2Name = extractPropertyName(property2) ?? ""

    // Try to parse method signature for parameter names
    if matchedMethod.contains("("),
       let paramsStart = matchedMethod.firstIndex(of: "(") {
      let paramsStr = String(matchedMethod[matchedMethod.index(after: paramsStart)...])
        .trimmingCharacters(in: CharacterSet(charactersIn: ")"))
      let params = paramsStr.split(separator: ",").compactMap { param -> String? in
        let parts = param.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let name = parts.first, !name.isEmpty else { return nil }
        return name
      }

      if params.isEmpty { return "\(baseName)()" }

      // Map parameter names to ViewModel properties
      let args = params.map { paramName -> String in
        let lower = paramName.lowercased()
        if !prop2Name.isEmpty && (lower.contains("search") || lower.contains("term") || lower.contains("query") || lower.contains("text")) {
          return "\(paramName): \(prop2Name)"
        }
        return "\(paramName): \(prop2Name.isEmpty ? paramName : prop2Name)"
      }
      return "\(baseName)(\(args.joined(separator: ", ")))"
    }

    // No signature info — infer from property2 (if it looks like a search/query property)
    if !prop2Name.isEmpty {
      let lower = prop2Name.lowercased()
      if lower.contains("search") || lower.contains("query") || lower.contains("term") || lower.contains("text") {
        return "\(baseName)(term: \(prop2Name))"
      }
    }
    return "\(baseName)()"
  }
}
