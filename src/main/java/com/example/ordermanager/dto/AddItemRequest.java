package com.example.ordermanager.dto;

import jakarta.validation.constraints.*;

import java.math.BigDecimal;

public class AddItemRequest {

    @NotBlank(message = "El nombre del producto es obligatorio")
    @Size(max = 150, message = "El nombre no puede superar 150 caracteres")
    private String productName;

    @NotNull(message = "La cantidad es obligatoria")
    @Min(value = 1, message = "La cantidad debe ser al menos 1")
    @Max(value = 1000, message = "La cantidad no puede superar 1000")
    private Integer quantity;

    @NotNull(message = "El precio unitario es obligatorio")
    @DecimalMin(value = "0.01", message = "El precio debe ser mayor a 0")
    @Digits(integer = 10, fraction = 2, message = "Formato de precio inválido")
    private BigDecimal unitPrice;

    public AddItemRequest() {}

    public AddItemRequest(String productName, Integer quantity, BigDecimal unitPrice) {
        this.productName = productName;
        this.quantity = quantity;
        this.unitPrice = unitPrice;
    }

    public String getProductName() { return productName; }
    public void setProductName(String productName) { this.productName = productName; }
    public Integer getQuantity() { return quantity; }
    public void setQuantity(Integer quantity) { this.quantity = quantity; }
    public BigDecimal getUnitPrice() { return unitPrice; }
    public void setUnitPrice(BigDecimal unitPrice) { this.unitPrice = unitPrice; }
}
